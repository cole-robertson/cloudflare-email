require_relative "../test_helper"
require "tmpdir"
require "fileutils"
require "cloudflare/email/active_record/routing_deliveries"
require "cloudflare/email/active_record/delivery_events"
require "generators/cloudflare/email/outbox/outbox_generator"
require "generators/cloudflare/email/tracking/tracking_generator"
require "generators/cloudflare/email/routing_tracking/routing_tracking_generator"

ROUTING_ROOT = Dir.mktmpdir("cloudflare-email-routing")
Minitest.after_run { FileUtils.remove_entry(ROUTING_ROOT) }
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(ROUTING_ROOT, "routing.sqlite3"), timeout: 5000, pool: 5)
ActiveRecord::Encryption.configure(primary_key: "test-primary-key", deterministic_key: "test-deterministic-key", key_derivation_salt: "test-salt")
ActiveRecord::Migration.verbose = false
[Cloudflare::Email::Generators::OutboxGenerator, Cloudflare::Email::Generators::TrackingGenerator,
 Cloudflare::Email::Generators::RoutingTrackingGenerator].each do |generator|
  generator.new([], {}, destination_root: ROUTING_ROOT).invoke_all
end
Dir[File.join(ROUTING_ROOT, "db/migrate/*.rb")].sort.each { |file| require file }
CreateCloudflareEmailOutbox.new.migrate(:up)
CreateCloudflareEmailEventReceipts.new.migrate(:up)
CreateCloudflareEmailRoutingDeliveryReceipts.new.migrate(:up)

class RoutingHostRecord < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "sqlite3", database: File.join(ROUTING_ROOT, "host.sqlite3"))
end
class RoutingHostProjection < RoutingHostRecord
  self.table_name = "host_projections"
end
RoutingHostRecord.connection.create_table(:host_projections) { |t| t.string :state }

class RoutingDeliveriesTest < Minitest::Test
  API = Cloudflare::Email::ActiveRecord::RoutingDeliveries
  Receipt = Cloudflare::Email::ActiveRecord::RoutingDeliveryReceipt
  Delivery = Cloudflare::Email::ActiveRecord::OutboundDelivery
  Recipient = Cloudflare::Email::ActiveRecord::OutboundRecipient
  Outbox = Cloudflare::Email::ActiveRecord::Outbox
  Evidence = Cloudflare::Email::RoutingAnalytics::Evidence

  def setup
    Receipt.delete_all
    Cloudflare::Email::ActiveRecord::EventReceipt.delete_all
    Recipient.delete_all
    Delivery.delete_all
    RoutingHostProjection.delete_all
    @time = Time.at(Time.now.to_i - 60).utc
  end

  def delivery(key: "operation", recipients: ["receiver@example.com"], **attrs)
    item = Outbox.prepare(account_id: attrs.delete(:account_id) || ACCOUNT_ID, operation_key: key, from: "sender@example.com",
      recipients: recipients, mime_message: "To: misleading@example.com\r\nSubject: test\r\n\r\nbody")
    item.update!({state: "accepted", provider_message_id: key, request_started_at: @time + 0.5}.merge(attrs))
    item.outbound_recipients.update_all(state: "queued", acceptance_state: "accepted")
    item
  end

  def evidence(key: "operation", **event_attrs)
    row = {"messageId" => key, "sessionId" => "session-#{key}", "datetime" => @time.iso8601,
        "eventType" => "newEmail", "status" => "delivered", "isNDR" => 0, "isLastEvent" => 1,
        "sampleInterval" => 1, "from" => "sender@example.com", "to" => "misleading@example.com"}.merge(event_attrs.transform_keys(&:to_s))
    Evidence.new("source" => "cloudflare_routing_analytics", "account_id" => ACCOUNT_ID, "zone_id" => "a" * 32,
      "query_started_at" => (@time - 10).iso8601, "query_finished_at" => (@time + 20).iso8601,
      "response" => {"data" => {"viewer" => {"zones" => [{"zoneTag" => "a" * 32, "emailRoutingAdaptive" => [row]}]}}},
      "event" => row)
  end

  def test_positive_singleton_is_encrypted_and_never_changes_acceptance_or_snapshot
    item = delivery
    snapshot = item.attributes.slice("state", "mime_message", "snapshot_digest", "recipients_json")
    receipt = API.record(delivery: item, evidence: evidence)
    raw = Receipt.connection.select_value("SELECT payload_json FROM #{Receipt.table_name} WHERE id = #{receipt.id}")
    refute_includes raw, "sender@example.com"
    assert_equal :applied, API.apply(receipt)
    assert_equal snapshot, item.reload.attributes.slice(*snapshot.keys)
    assert_equal ["delivered", true, "accepted"], item.outbound_recipients.first.attributes.values_at("state", "terminal", "acceptance_state")
    assert_equal "applied", receipt.reload.state
    assert_equal 0, Cloudflare::Email::ActiveRecord::OutboundReconciliation.count
  end

  def test_record_and_apply_are_idempotent_with_different_query_windows
    item = delivery
    receipt = API.record(delivery: item, evidence: evidence)
    changed_window = Evidence.new(evidence.payload.merge("query_started_at" => (@time - 20).iso8601))
    assert_equal receipt.id, API.record(delivery: item, evidence: changed_window).id
    callbacks = 0
    2.times { API.apply(receipt) { callbacks += 1 } }
    assert_equal 1, callbacks
    assert_equal 1, Receipt.count
    assert_raises(API::InvalidEvidence) { API.record(delivery: item, evidence: evidence(to: "changed@example.com")) }
  end

  def test_correlation_rejects_account_id_sender_start_state_and_collisions
    [{account_id: "wrong"}, {provider_message_id: "wrong"}, {request_started_at: @time + 2},
      {state: "uncertain"}, {state: "partial"}].each do |attrs|
      item = delivery(key: SecureRandom.hex(4), **attrs)
      assert_raises(API::InvalidEvidence) { API.record(delivery: item, evidence: evidence(key: item.operation_key)) }
    end
    item = delivery
    assert_raises(API::InvalidEvidence) { API.record(delivery: item, evidence: evidence(from: "other@example.com")) }
    delivery(key: "collision", provider_message_id: "<operation>", state: "partial")
    assert_raises(API::InvalidEvidence) { API.record(delivery: item, evidence: evidence) }
    assert_equal 0, Receipt.count
  end

  def test_only_saved_envelope_can_identify_recipient
    item = delivery(recipients: ["one@example.com", "two@example.com"])
    assert_raises(API::InvalidEvidence) { API.record(delivery: item, evidence: evidence) }
    item = delivery(key: "mismatch")
    Recipient.where(outbound_delivery_id: item.id).update_all(recipient: "wrong@example.com")
    assert_raises(API::InvalidEvidence) { API.record(delivery: item, evidence: evidence(key: "mismatch")) }
  end

  def test_delivery_overrides_equal_or_later_nonterminal_facts
    [@time, @time + 15].each_with_index do |occurred_at, i|
      item = delivery(key: i.to_s)
      item.outbound_recipients.update_all(occurred_at: occurred_at)
      API.apply(API.record(delivery: item, evidence: evidence(key: i.to_s)))
      assert_equal "delivered", item.outbound_recipients.reload.first.state
    end
  end

  def test_terminal_webhook_facts_are_preserved
    item = delivery
    item.outbound_recipients.update_all(state: "bounced", terminal: true, occurred_at: @time - 10)
    API.apply(API.record(delivery: item, evidence: evidence)) { flunk "must preserve terminal fact" }
    assert_equal "bounced", item.outbound_recipients.reload.first.state
  end

  def test_later_genuine_sending_complaint_still_applies
    item = delivery
    API.apply(API.record(delivery: item, evidence: evidence))
    event = Cloudflare::Email::DeliveryEvent.new("type" => "cf.email.sending.message.complained",
      "source" => {"type" => "email.sending", "domain" => "example.com"},
      "metadata" => {"eventSchemaVersion" => 1, "accountId" => ACCOUNT_ID, "eventTimestamp" => (@time + 10).iso8601},
      "payload" => {"eventId" => "complaint-1", "messageId" => "operation", "recipient" => "receiver@example.com", "terminal" => true})
    Cloudflare::Email::ActiveRecord::DeliveryEvents.record(event)
    assert_equal "complained", item.outbound_recipients.reload.first.state
    API.apply(Receipt.first)
    assert_equal "complained", item.outbound_recipients.reload.first.state
  end

  def test_callback_rollback_retains_pending_receipt_and_safe_replay
    item = delivery
    receipt = API.record(delivery: item, evidence: evidence)
    assert_raises(RuntimeError) do
      API.apply(receipt) do |stored, _recipient|
        stored.update!(error_class: "same-db-business-projection")
        raise "callback failed"
      end
    end
    assert_equal "pending", receipt.reload.state
    assert_equal "queued", item.outbound_recipients.reload.first.state
    assert_nil item.reload.error_class
    assert_equal :applied, API.apply(receipt)
  end

  def test_intake_rejects_ambient_transaction
    item = delivery
    Receipt.transaction do
      assert_raises(ArgumentError) { API.record(delivery: item, evidence: evidence) }
    end
    assert_equal 0, Receipt.count
  end

  def test_explicit_active_record_rollback_cannot_commit_recipient_without_callback
    item = delivery
    receipt = API.record(delivery: item, evidence: evidence)
    assert_raises(ArgumentError) do
      API.apply(receipt) do |stored, _recipient|
        stored.update!(error_class: "must-rollback")
        raise ActiveRecord::Rollback
      end
    end
    assert_equal "pending", receipt.reload.state
    assert_equal "queued", item.outbound_recipients.reload.first.state
    assert_nil item.reload.error_class
    calls = 0
    API.apply(receipt) { calls += 1 }
    assert_equal 1, calls
  end

  def test_bounded_replay_progresses_past_poison_receipts
    3.times do |i|
      item = delivery(key: i.to_s)
      API.record(delivery: item, evidence: evidence(key: i.to_s))
    end
    first = API.replay(account_id: ACCOUNT_ID, limit: 2) { raise "business projection failure" }
    assert_equal 2, first.processed
    assert_equal 2, first.errors.length
    refute first.finished
    last = API.replay(account_id: ACCOUNT_ID, limit: 2, after_id: first.after_id)
    assert_equal 1, last.processed
    assert last.finished
    assert_equal 2, Receipt.where(state: "pending").count
    assert_equal 2, API.replay(account_id: ACCOUNT_ID).processed
    assert_equal 0, Receipt.where(state: "pending").count
  end

  def test_applied_receipt_can_be_replayed_after_external_database_rollback
    item = delivery
    receipt = API.record(delivery: item, evidence: evidence)
    projection = RoutingHostProjection.create!(state: "pending")
    assert_raises(RuntimeError) do
      RoutingHostProjection.transaction do
        API.apply(receipt)
        projection.update!(state: "delivered")
        raise "crash after tenant commit before shared commit"
      end
    end
    assert_equal "pending", projection.reload.state
    assert_equal "applied", receipt.reload.state
    copy = Receipt.find(receipt.id)
    RoutingHostProjection.transaction do
      assert_equal :applied, API.apply(copy) { flunk "must not repeat committed callback" }
      projection.update!(state: item.outbound_recipients.reload.first.state)
    end
    assert_equal "delivered", projection.reload.state
    assert_equal receipt.id, API.record(delivery: item, evidence: evidence).id
    assert_equal 1, Receipt.count
  end

  def test_generator_repeat_does_not_add_duplicate_migrations
    files = Dir[File.join(ROUTING_ROOT, "db/migrate/*.rb")].sort
    Cloudflare::Email::Generators::RoutingTrackingGenerator.new([], {}, destination_root: ROUTING_ROOT).invoke_all
    assert_equal files, Dir[File.join(ROUTING_ROOT, "db/migrate/*.rb")].sort
    assert_includes File.read(File.join(ROUTING_ROOT, "config/initializers/cloudflare_email_routing_tracking.rb")),
      'require "cloudflare/email/active_record/routing_deliveries"'
  end

  def test_concurrent_intake_cannot_duplicate_identity
    item = delivery
    ready, go, outcomes = Queue.new, Queue.new, Queue.new
    threads = 2.times.map do
      Thread.new do
        Receipt.connection_pool.with_connection do
          ready << true
          go.pop
          begin
            outcomes << API.record(delivery: Delivery.find(item.id), evidence: evidence)
          rescue ActiveRecord::StatementInvalid => error
            # SQLite may serialize through a busy failure; the caller replays
            # intake. Constraint enforcement must still retain only one row.
            outcomes << error
          end
        end
      end
    end
    2.times { ready.pop }
    2.times { go << true }
    threads.each(&:join)
    results = 2.times.map { outcomes.pop }
    assert results.any? { |value| value.is_a?(Receipt) }
    receipt = API.record(delivery: item, evidence: evidence)
    assert_equal 1, Receipt.count
    assert_equal :applied, API.apply(receipt)
  end
end
