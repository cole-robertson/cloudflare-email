require_relative "../test_helper"
require "active_record"
require "tmpdir"
require "fileutils"
require "cloudflare/email/tenancy"
require "cloudflare/email/mailboxes/configuration"

EVENT_TENANT_ROOT = Dir.mktmpdir("cf-mailbox-events")
Minitest.after_run { FileUtils.remove_entry(EVENT_TENANT_ROOT) }
class EventsDirectoryRecord < ActiveRecord::Base
  self.abstract_class = true
end
class EventsTenantRecord < ActiveRecord::Base
  self.abstract_class = true
end
EventsDirectoryRecord.establish_connection(adapter: "sqlite3", database: File.join(EVENT_TENANT_ROOT, "directory.sqlite3"))
Cloudflare::Email::Tenancy.configure(base_class: EventsTenantRecord,
  current: -> { Thread.current[:events_test_tenant] },
  switch: ->(key, &block) {
    previous = Thread.current[:events_test_tenant]
    EventsTenantRecord.establish_connection(adapter: "sqlite3", database: File.join(EVENT_TENANT_ROOT, "#{key}.sqlite3"))
    Thread.current[:events_test_tenant] = key
    begin
      block.call
    ensure
      Thread.current[:events_test_tenant] = previous
      EventsTenantRecord.establish_connection(adapter: "sqlite3", database: File.join(EVENT_TENANT_ROOT, "#{previous}.sqlite3")) if previous
    end
  })
Cloudflare::Email::Mailboxes.configure(directory_base: EventsDirectoryRecord)
require "cloudflare/email/mailboxes/models"
require "cloudflare/email/mailboxes/events"
require "generators/cloudflare/email/mailboxes/templates/create_cloudflare_email_shared_events"
require "generators/cloudflare/email/outbox/templates/create_cloudflare_email_outbox"
require "generators/cloudflare/email/tracking/templates/create_cloudflare_email_event_receipts"

ActiveRecord::Migration.verbose = false
# Migrations use ActiveRecord::Base; point it at each physical database while
# model connections continue to use their explicitly configured base classes.
ActiveRecord::Base.establish_connection(EventsDirectoryRecord.connection_db_config.configuration_hash)
CreateCloudflareEmailSharedEvents.new.migrate(:up)
ActiveRecord::Schema.define do
  create_table :cloudflare_email_receiving_domains do |t|
    t.string :domain
    t.string :tenant_key
    t.string :account_id
    t.string :state
  end
end
%w[alpha beta].each do |key|
  Cloudflare::Email::Tenancy.with(key) do
    ActiveRecord::Base.establish_connection(EventsTenantRecord.connection_db_config.configuration_hash)
    CreateCloudflareEmailOutbox.new.migrate(:up)
    CreateCloudflareEmailEventReceipts.new.migrate(:up)
    ActiveRecord::Schema.define do
      create_table :cloudflare_email_mailbox_outbound_messages do |t|
        t.string :tenant_key
        t.bigint :outbound_delivery_id
        t.bigint :mailbox_id
      end
    end
  end
end

class TenantMailboxEventsTest < Minitest::Test
  Email = Cloudflare::Email
  Events = Email::Mailboxes::Events
  Receipt = Email::Mailboxes::SharedEventReceipt
  Correlation = Email::Mailboxes::ProviderCorrelation
  Tenancy = Email::Tenancy
  Outbox = Email::ActiveRecord::Outbox
  Delivery = Email::ActiveRecord::OutboundDelivery

  def setup
    Receipt.delete_all
    Correlation.delete_all
    Email::Mailboxes::ReceivingDomain.delete_all
    %w[alpha beta].each do |key|
      Email::Mailboxes::ReceivingDomain.create!(domain: "#{key}.example.com", account_id: "account", tenant_key: key, state: "active")
      Tenancy.with(key) do
        Email::Mailboxes::OutboundMessage.delete_all
        Email::ActiveRecord::EventReceipt.delete_all
        Email::ActiveRecord::OutboundRecipient.delete_all
        Delivery.delete_all
      end
    end
  end

  def event(id: "event", message_id: "provider")
    Email::DeliveryEvent.new("type" => "cf.email.sending.message.delivered",
      "source" => { "type" => "email.sending", "domain" => "alpha.example.com" },
      "metadata" => { "accountId" => "account", "eventSchemaVersion" => 1, "eventTimestamp" => "2026-09-11T10:00:00Z" },
      "payload" => { "eventId" => id, "messageId" => message_id, "recipient" => "reader@example.net", "terminal" => true })
  end

  def accepted(key, register: true)
    Tenancy.with(key) do
      delivery = Outbox.prepare(account_id: "account", operation_key: key,
        from: "sender@#{key}.example.com", recipients: ["reader@example.net"], mime_message: "Subject: test\r\n\r\nhello")
      delivery.update!(state: "accepted", provider_message_id: "provider")
      delivery.outbound_recipients.update_all(state: "accepted", acceptance_state: "accepted")
      Email::Mailboxes::OutboundMessage.insert_all!([{ tenant_key: key, outbound_delivery_id: delivery.id, mailbox_id: 1 }])
      Events.register(delivery) if register
      delivery.id
    end
  end

  def test_event_before_registration_is_durable_then_routes_only_to_owner
    alpha_id = accepted("alpha", register: false)
    accepted("beta", register: false)
    receipt = Events.record(event)
    assert_equal "unmatched", Events.apply(receipt).state
    assert_equal receipt.id, Events.record(event).id
    Tenancy.with("alpha") { Events.register(Delivery.find(alpha_id)) }
    calls = 0
    Events.replay { calls += 1 }
    assert_equal "applied", receipt.reload.state
    Events.apply(receipt) { calls += 1 }
    assert_equal 1, calls
    Tenancy.with("alpha") { assert_equal "delivered", Delivery.find(alpha_id).outbound_recipients.first.state }
    Tenancy.with("beta") { assert_equal "accepted", Delivery.first.outbound_recipients.first.state }
  end

  def test_cross_tenant_provider_collision_is_retained_without_projection
    accepted("alpha")
    accepted("beta")
    receipt = Events.record(event)
    assert_equal "unmatched", Events.apply(receipt).state
    %w[alpha beta].each do |key|
      Tenancy.with(key) { assert_equal 0, Email::ActiveRecord::EventReceipt.count }
    end
  end

  def test_shared_failure_after_tenant_commit_replays_without_duplicate_callback
    accepted("alpha")
    receipt = Events.record(event)
    calls = 0
    Events.apply(receipt) { calls += 1 }
    # Model the shared completion write having failed after the tenant commit.
    receipt.update!(state: "pending", applied_at: nil)
    Events.apply(receipt) { calls += 1 }
    assert_equal "applied", receipt.reload.state
    assert_equal 1, calls
  end

  def test_failed_tenant_callback_rolls_back_projection_and_can_replay
    accepted("alpha")
    receipt = Events.record(event)
    assert_raises(RuntimeError) { Events.apply(receipt) { raise "application callback failed" } }
    assert_equal "pending", receipt.reload.state
    Tenancy.with("alpha") { assert_equal "accepted", Delivery.first.outbound_recipients.first.state }
    assert_equal "applied", Events.apply(receipt).state
  end

  def test_payload_conflicts_and_outer_transactions_are_rejected
    receipt = Events.record(event)
    assert_raises(Email::ValidationError) { Events.record(event(message_id: "other")) }
    Receipt.transaction do
      assert_raises(ArgumentError) { Events.record(event(id: "other")) }
      assert_raises(ArgumentError) { Events.apply(receipt) }
    end
    assert_equal 1, Receipt.count
    begin
      receipt.update!(payload_json: JSON.generate(event(message_id: "tampered").raw))
    rescue ActiveRecord::ReadonlyAttributeError
      # Supported Rails releases differ in whether readonly assignment raises.
    end
    assert_equal "provider", receipt.reload.event.message_id
  end

  def test_replay_is_bounded_and_cursor_can_advance_past_unmatched
    3.times { |i| Events.record(event(id: "event#{i}")) }
    page = Events.replay(limit: 2)
    assert_equal 2, page.length
    assert_equal 1, Events.replay(limit: 2, after_id: page.last.id).length
    assert_raises(ArgumentError) { Events.replay(limit: 1001) }
  end

  def test_suspended_directory_prevents_projection
    accepted("alpha")
    Email::Mailboxes::ReceivingDomain.find_by!(tenant_key: "alpha").update!(state: "suspended")
    assert_equal "unmatched", Events.apply(Events.record(event)).state
  end

  def test_registration_requires_current_owner_and_rejects_cross_tenant_instances
    id = accepted("alpha", register: false)
    leaked = Tenancy.with("alpha") { Delivery.find(id) }
    assert_raises(Email::ConfigurationError) { Events.register(leaked) }
    Tenancy.with("alpha") do
      assert_raises(Email::ConfigurationError) { Events.register(leaked, tenant_key: "beta") }
    end
    Tenancy.with("beta") do
      assert_raises(Email::ConfigurationError) { Events.register(leaked) }
    end
    assert_equal 0, Correlation.count
  end
end
