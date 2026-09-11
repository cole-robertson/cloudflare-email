# Run only against a disposable database. Each run uses and drops its own schema.
# POSTGRES_TEST_URL=postgres://localhost/cloudflare_email_test \
#   BUNDLE_GEMFILE=gemfiles/postgres.gemfile bundle exec ruby script/verify_postgres_outbox.rb
require "securerandom"
require "timeout"
require "pg"
require_relative "../test/test_helper"
require "cloudflare/email/active_record/outbox"
require "cloudflare/email/active_record/event_inbox"
require "cloudflare/email/active_record/delivery_events"
require_relative "../lib/generators/cloudflare/email/outbox/templates/create_cloudflare_email_outbox"
require_relative "../lib/generators/cloudflare/email/tracking/templates/create_cloudflare_email_event_receipts"

url = ENV.fetch("POSTGRES_TEST_URL")
schema = "cf_email_verify_#{SecureRandom.hex(8)}"
ActiveRecord::Base.establish_connection(url: url, pool: 12, checkout_timeout: 10)
ActiveRecord::Base.connection.execute("CREATE SCHEMA #{schema}")
ActiveRecord::Base.establish_connection(url: url, pool: 12, checkout_timeout: 10, schema_search_path: schema)
Minitest.after_run do
  ActiveRecord::Base.connection.execute("DROP SCHEMA #{schema} CASCADE")
  ActiveRecord::Base.connection_pool.disconnect!
end
ActiveRecord::Migration.verbose = false
CreateCloudflareEmailOutbox.new.migrate(:up)
CreateCloudflareEmailEventReceipts.new.migrate(:up)
ActiveRecord::Schema.define do
  create_table :postgres_projection_effects do |table|
    table.string :delivery_state
  end
end

class PostgresProjectionEffect < ActiveRecord::Base
end

class PostgresOutboxTest < Minitest::Test
  Outbox = Cloudflare::Email::ActiveRecord::Outbox
  Delivery = Cloudflare::Email::ActiveRecord::OutboundDelivery
  Inbox = Cloudflare::Email::ActiveRecord::EventInbox
  Receipt = Cloudflare::Email::ActiveRecord::EventReceipt
  Events = Cloudflare::Email::ActiveRecord::DeliveryEvents

  # A barrier inside the provider proves different operations can send together,
  # without relying on elapsed-time thresholds or accessing a remote provider.
  class Client
    attr_reader :account_id, :calls
    def initialize(entered: nil, release: nil, error: nil, before_response: nil)
      @account_id = "postgres-test-account"
      @calls = Queue.new
      @entered, @release, @error = entered, release, error
      @before_response = before_response
    end

    def retry_ambiguous = false

    def send_raw(**message)
      @calls << message
      @entered << true if @entered
      Timeout.timeout(10) { @release.pop } if @release
      @before_response&.call
      raise @error if @error
      Cloudflare::Email::Response.new({ "success" => true, "result" => {
        "message_id" => "provider-#{SecureRandom.hex(8)}", "queued" => message.fetch(:recipients)
      } })
    end
  end

  def prepare(key = SecureRandom.uuid, body: "PostgreSQL verification")
    Outbox.prepare(account_id: "postgres-test-account", operation_key: key,
      from: "sender@example.test", recipients: ["receiver@example.test"],
      mime_message: "From: sender@example.test\r\nTo: receiver@example.test\r\nSubject: verification\r\n\r\n#{body}")
  end

  def concurrent(count)
    start = Queue.new
    threads = count.times.map do |i|
      Thread.new do
        Thread.current.report_on_exception = false
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          yield i
        end
      end
    end
    count.times { start << true }
    Timeout.timeout(20) { threads.map(&:value) }
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
  end

  def test_concurrent_identical_operations_create_one_snapshot_and_send_once
    key = SecureRandom.uuid
    client = Client.new
    results = concurrent(8) do
      delivery = prepare(key)
      begin
        Outbox.deliver(delivery, client: client)
      rescue Outbox::InvalidTransition
        # Another worker already owns the committed sending claim.
      end
      delivery.id
    end
    assert_equal 1, results.uniq.size
    assert_equal 1, Delivery.where(operation_key: key).count
    assert_equal 1, client.calls.size
    assert_equal "accepted", Delivery.find(results.first).state
  end

  def test_concurrent_conflicting_snapshots_cannot_replace_winner
    key = SecureRandom.uuid
    results = concurrent(2) do |i|
      prepare(key, body: "body #{i}").id
    rescue Outbox::SnapshotConflict
      :conflict
    end
    assert_equal 1, results.count(:conflict)
    assert_equal 1, Delivery.where(operation_key: key).count
  end

  def test_distinct_operations_do_not_hold_database_locks_during_provider_request
    entered, release = Queue.new, Queue.new
    client = Client.new(entered: entered, release: release)
    deliveries = [prepare, prepare]
    releaser = Thread.new do
      Thread.current.report_on_exception = false
      Timeout.timeout(10) { 2.times { entered.pop } }
      2.times { release << true }
    end
    results = concurrent(2) { |i| Outbox.deliver(deliveries[i], client: client) }
    releaser.value
    assert_equal 2, results.size
    assert_equal 2, client.calls.size
    assert_equal ["accepted", "accepted"], deliveries.map { |row| row.reload.state }
  ensure
    releaser&.kill if releaser&.alive?
    releaser&.join
  end

  def event
    fixture = JSON.parse(File.read(File.expand_path("../test/fixtures/email_sending_queue_message.json", __dir__)))
    raw = JSON.parse(fixture.fetch("body"))
    raw["payload"]["eventId"] = SecureRandom.uuid
    Cloudflare::Email::DeliveryEvent.new(raw)
  end

  def test_lost_database_connection_after_request_cannot_unlock_automatic_retry
    delivery = prepare
    client = Client.new(error: Net::ReadTimeout.new("provider response lost"), before_response: lambda {
      # Kill only this test's own checked-out backend after the claim committed.
      backend = ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
      PG.connect(ENV.fetch("POSTGRES_TEST_URL")) do |connection|
        assert_equal "t", connection.exec_params("SELECT pg_terminate_backend($1)", [backend]).getvalue(0, 0)
      end
    })
    assert_raises(Net::ReadTimeout) { Outbox.deliver(delivery, client: client) }
    ActiveRecord::Base.connection.reconnect!
    assert_includes %w[sending unknown], delivery.reload.state
    assert_raises(Outbox::InvalidTransition) { Outbox.deliver(delivery, client: client) }
    assert_equal 1, client.calls.size
  end

  def test_duplicate_receipt_is_applied_once_with_postgres_row_lock
    delivery_event = event
    handled = Queue.new
    results = concurrent(8) do
      receipt = Inbox.record(delivery_event)
      Inbox.apply(receipt) do
        handled << true
        :applied
      end
      receipt.id
    end
    assert_equal 1, results.uniq.size
    assert_equal 1, handled.size
    assert_equal "applied", Receipt.find(results.first).state
  end

  def projected_event(delivery, status: "delivered", at: Time.now.utc + 60, terminal: true, account: delivery.account_id)
    raw = event.raw
    raw["type"] = "cf.email.sending.message.#{status}"
    raw["metadata"]["accountId"] = account
    raw["metadata"]["eventTimestamp"] = at.iso8601(6)
    raw["payload"]["messageId"] = "<#{delivery.provider_message_id}>"
    raw["payload"]["recipient"] = delivery.recipients.first
    raw["payload"]["terminal"] = terminal
    Cloudflare::Email::DeliveryEvent.new(raw)
  end

  def test_different_concurrent_receipts_cannot_regress_terminal_recipient
    delivery = Outbox.deliver(prepare, client: Client.new)
    at = Time.now.utc + 60
    delivered = projected_event(delivery, at: at)
    deferred = projected_event(delivery, status: "deferred", at: at - 1, terminal: false)
    # Reverse thread launch order for a second independent concurrent run.
    [[delivered, deferred], [deferred, delivered]].each do |events|
      recipient = delivery.outbound_recipients.first
      recipient.update!(state: "queued", occurred_at: nil, terminal: false)
      events.each { |entry| Receipt.where(event_id: entry.event_id).delete_all }
      receipts = concurrent(2) { |i| Events.record(events[i]) }
      assert_equal ["applied", "applied"], receipts.map { |receipt| receipt.reload.state }
      assert_equal "delivered", recipient.reload.state
      assert recipient.terminal?
      assert_equal at.iso8601(6), recipient.occurred_at.utc.iso8601(6)
      assert_equal "accepted", delivery.reload.state
    end
    # Even a newer nonterminal event cannot undo a terminal outcome.
    receipt = Events.record(projected_event(delivery, status: "deferred", at: at + 1, terminal: false))
    assert_equal "applied", receipt.state
    assert_equal "delivered", delivery.outbound_recipients.first.state
  end

  def test_duplicate_projection_receipts_invoke_callback_once
    delivery = Outbox.deliver(prepare, client: Client.new)
    delivery_event = projected_event(delivery)
    effects = Queue.new
    receipts = concurrent(8) { Events.record(delivery_event) { effects << true } }
    assert_equal 1, receipts.map(&:id).uniq.size
    assert_equal 1, effects.size
    assert_equal "delivered", delivery.outbound_recipients.first.state
  end

  def test_ambiguous_provider_id_and_wrong_account_remain_unmatched
    delivery = Outbox.deliver(prepare, client: Client.new)
    wrong_account = Events.record(projected_event(delivery, account: "different-account"))
    assert_equal "unmatched", wrong_account.state
    duplicate = Outbox.deliver(prepare, client: Client.new)
    duplicate.update!(provider_message_id: delivery.provider_message_id)
    ambiguous = Events.record(projected_event(delivery))
    assert_equal "unmatched", ambiguous.state
    assert_equal ["queued", "queued"], [delivery, duplicate].map { |row| row.outbound_recipients.first.state }
  end

  def test_projection_callback_failure_rolls_back_state_and_database_effect_then_replays_once
    delivery = Outbox.deliver(prepare, client: Client.new)
    delivery_event = projected_event(delivery)
    before_count = PostgresProjectionEffect.count
    assert_raises(RuntimeError) do
      Events.record(delivery_event) do |_row, recipient|
        PostgresProjectionEffect.create!(delivery_state: recipient.state)
        raise "application projection failed"
      end
    end
    assert_equal before_count, PostgresProjectionEffect.count
    assert_equal "queued", delivery.outbound_recipients.first.state
    receipt = Receipt.find_by!(event_id: delivery_event.event_id)
    assert_equal "pending", receipt.state
    callback = ->(_row, recipient) { PostgresProjectionEffect.create!(delivery_state: recipient.state) }
    assert_equal 1, Events.replay(account_id: delivery.account_id, message_id: delivery_event.message_id, &callback)
    assert_equal 0, Events.replay(account_id: delivery.account_id, message_id: delivery_event.message_id, &callback)
    assert_equal before_count + 1, PostgresProjectionEffect.count
    assert_equal "applied", receipt.reload.state
    assert_equal "delivered", delivery.outbound_recipients.first.state
  end
end
