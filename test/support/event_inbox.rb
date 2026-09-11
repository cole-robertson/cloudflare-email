require_relative "../test_helper"
require "tmpdir"
require "fileutils"
require "cloudflare/email/active_record/event_inbox"
require "generators/cloudflare/email/tracking/tracking_generator"

TRACKING_ROOT = Dir.mktmpdir("cloudflare-email-tracking")
Minitest.after_run { FileUtils.remove_entry(TRACKING_ROOT) }
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(TRACKING_ROOT, "events.sqlite3"), timeout: 2000)
ActiveRecord::Migration.verbose = false
Cloudflare::Email::Generators::TrackingGenerator.new([], {}, destination_root: TRACKING_ROOT).invoke_all
require Dir[File.join(TRACKING_ROOT, "db/migrate/*.rb")].fetch(0)
CreateCloudflareEmailEventReceipts.new.migrate(:up)
ActiveRecord::Schema.define do
  create_table :tracking_test_messages do |t|
    t.string :provider_id
    t.string :delivery_status
  end
end

class TrackingTestMessage < ActiveRecord::Base
end

class EventInboxTest < Minitest::Test
  Inbox = Cloudflare::Email::ActiveRecord::EventInbox
  Receipt = Cloudflare::Email::ActiveRecord::EventReceipt

  def setup
    Receipt.delete_all
    TrackingTestMessage.delete_all
  end

  def event(account: "test-account-123", id: "event-123", message: "message-456")
    fixture = JSON.parse(File.read(File.expand_path("../fixtures/email_sending_queue_message.json", __dir__)))
    raw = JSON.parse(fixture.fetch("body"))
    raw["metadata"]["accountId"] = account
    raw["payload"]["eventId"] = id
    raw["payload"]["messageId"] = message
    Cloudflare::Email::DeliveryEvent.new(raw)
  end

  def test_generator_produces_packaged_migration_and_initializer
    assert File.read(File.join(TRACKING_ROOT, "config/initializers/cloudflare_email_tracking.rb")).include?("cloudflare/email/active_record/event_inbox")
    unique = Receipt.connection.indexes(Receipt.table_name).find(&:unique)
    assert_equal ["account_id", "event_id"], unique.columns
    spec = Gem::Specification.load(File.expand_path("../../cloudflare-email.gemspec", __dir__))
    assert_includes spec.files, "lib/generators/cloudflare/email/tracking/templates/create_cloudflare_email_event_receipts.rb"
  end

  def test_record_is_durable_idempotent_and_scoped_to_account
    receipt = Inbox.record(event)
    assert_equal "pending", receipt.reload.state
    assert_equal event.raw, receipt.event.raw
    assert_equal receipt.id, Inbox.record(event).id
    refute_equal receipt.id, Inbox.record(event(account: "another-account")).id
    assert_equal 2, Receipt.count
    duplicate = receipt.attributes.except("id")
    assert_raises(ActiveRecord::RecordNotUnique) { Receipt.insert_all!([duplicate]) }
  end

  def test_conflicting_duplicate_never_overwrites_original
    receipt = Inbox.record(event)
    assert_raises(Cloudflare::Email::ValidationError) { Inbox.record(event(message: "another-message")) }
    assert_equal "message-456", receipt.reload.message_id
    assert_equal "message-456", receipt.event.message_id
  end

  def test_receipt_identity_and_payload_remain_immutable_after_recording
    receipt = Inbox.record(event)
    original = receipt.attributes.slice("account_id", "event_id", "message_id", "payload_json")
    original.each_key do |field|
      begin
        receipt.public_send("#{field}=", "changed")
        receipt.save!
      rescue ActiveRecord::ReadonlyAttributeError
        # Rails versions either reject assignment or omit readonly updates.
      end
      assert_equal original, receipt.reload.attributes.slice(*original.keys)
    end
    Inbox.apply(receipt) { :applied }
    assert_equal "applied", receipt.reload.state
    assert_equal original, receipt.attributes.slice(*original.keys)
  end

  def test_concurrent_duplicate_recording_uses_database_unique_constraint
    results = Queue.new
    threads = 4.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          results << Inbox.record(event).id
        rescue => error
          results << error
        end
      end
    end
    threads.each(&:join)
    ids = 4.times.map { results.pop }
    assert ids.all? { |value| value.is_a?(Integer) }, ids.inspect
    assert_equal 1, ids.uniq.length
    assert_equal 1, Receipt.count
  end

  def test_record_refuses_uncommitted_outer_transaction
    ActiveRecord::Base.transaction do
      assert_raises(ArgumentError) { Inbox.record(event) }
    end
    assert_equal 0, Receipt.count
  end

  def test_apply_commits_handler_writes_and_skips_duplicate_application
    receipt = Inbox.record(event)
    stale = Receipt.find(receipt.id)
    Inbox.apply(receipt) do |delivery|
      TrackingTestMessage.create!(provider_id: delivery.message_id, delivery_status: delivery.status)
      :applied
    end
    assert_equal "applied", receipt.reload.state
    refute_nil receipt.applied_at
    assert_equal "delivered", TrackingTestMessage.first.delivery_status
    Inbox.apply(stale) { flunk "already applied event was replayed" }
    assert_equal 1, TrackingTestMessage.count
  end

  def test_handler_failure_rolls_back_database_changes_but_retains_receipt
    receipt = Inbox.record(event)
    assert_raises(RuntimeError) do
      Inbox.apply(receipt) do
        TrackingTestMessage.create!(provider_id: "message-456")
        raise "application processing failed"
      end
    end
    assert_equal "pending", receipt.reload.state
    assert_equal 0, TrackingTestMessage.count
    assert_equal 1, Receipt.count
  end

  def test_invalid_handler_outcome_rolls_back_instead_of_silently_acknowledging_application
    [nil, false, true, :ignored].each do |outcome|
      receipt = Inbox.record(event(id: "event-#{outcome.inspect}"))
      assert_raises(ArgumentError) do
        Inbox.apply(receipt) do
          TrackingTestMessage.create!(provider_id: "message-456")
          outcome
        end
      end
      assert_equal "pending", receipt.reload.state
    end
    assert_equal 0, TrackingTestMessage.count
  end

  def test_explicit_active_record_rollback_does_not_report_success
    receipt = Inbox.record(event)
    assert_raises(ArgumentError) do
      Inbox.apply(receipt) { raise ActiveRecord::Rollback }
    end
    assert_equal "pending", receipt.reload.state
  end

  def test_handler_rollback_inside_outer_transaction_uses_savepoint
    receipt = Inbox.record(event)
    ActiveRecord::Base.transaction do
      assert_raises(ArgumentError) do
        Inbox.apply(receipt) do
          TrackingTestMessage.create!(provider_id: "must-rollback")
          raise ActiveRecord::Rollback
        end
      end
      TrackingTestMessage.create!(provider_id: "outer-kept")
    end
    assert_equal ["outer-kept"], TrackingTestMessage.pluck(:provider_id)
    assert_equal "pending", receipt.reload.state
  end

  def test_unmatched_receipt_can_be_replayed_after_provider_id_is_stored
    receipt = Inbox.record(event)
    handler = lambda do |delivery|
      message = TrackingTestMessage.find_by(provider_id: delivery.message_id)
      next :unmatched unless message
      message.update!(delivery_status: delivery.status)
      :applied
    end
    Inbox.apply(receipt, &handler)
    assert_equal "unmatched", receipt.reload.state
    assert_nil receipt.applied_at
    TrackingTestMessage.create!(provider_id: "message-456")
    Inbox.record(event(account: "another-account"))
    Inbox.record(event(message: "another-message", id: "event-2"))
    assert_equal 1, Inbox.replay(account_id: "test-account-123", message_id: "message-456", batch_size: 1, &handler)
    assert_equal "applied", receipt.reload.state
    assert_equal "delivered", TrackingTestMessage.first.delivery_status
    assert_equal 2, Receipt.where(state: "pending").count
    assert_equal 0, Inbox.replay(account_id: "test-account-123", message_id: "message-456", &handler)
  end

  def test_queue_ack_observes_committed_receipt_and_redelivery_deduplicates
    client = Cloudflare::Email::EventConsumer.new(account_id: "test-account-123", api_token: "queue-token", queue_id: "queue-1")
    fixture = JSON.parse(File.read(File.expand_path("../fixtures/email_sending_queue_message.json", __dir__)))
    fixture["lease_id"] = "lease-1"
    base = "https://api.cloudflare.com/client/v4/accounts/test-account-123/queues/queue-1/messages"
    stub_request(:post, "#{base}/pull").to_return(body: JSON.generate(success: true, result: { messages: [fixture] }))
    acknowledgments = 0
    stub_request(:post, "#{base}/ack").to_return do
      refute Receipt.connection.transaction_open?
      assert_equal 1, Receipt.count
      acknowledgments += 1
      { body: JSON.generate(success: true, result: { ackCount: 1 }) }
    end
    2.times { client.poll { |delivery| Inbox.record(delivery) } }
    assert_equal 2, acknowledgments
    assert_equal 1, Receipt.count
  end

  def test_record_failure_prevents_queue_ack
    Inbox.record(event(message: "conflicting-message"))
    client = Cloudflare::Email::EventConsumer.new(account_id: "test-account-123", api_token: "queue-token", queue_id: "queue-1")
    fixture = JSON.parse(File.read(File.expand_path("../fixtures/email_sending_queue_message.json", __dir__)))
    fixture["lease_id"] = "lease-1"
    base = "https://api.cloudflare.com/client/v4/accounts/test-account-123/queues/queue-1/messages"
    stub_request(:post, "#{base}/pull").to_return(body: JSON.generate(success: true, result: { messages: [fixture] }))
    assert_raises(Cloudflare::Email::ValidationError) { client.poll { |delivery| Inbox.record(delivery) } }
    assert_not_requested :post, "#{base}/ack"
    assert_equal "conflicting-message", Receipt.first.message_id
  end
end
