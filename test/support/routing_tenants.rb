require_relative "../test_helper"
require "tmpdir"
require "fileutils"
require "active_record"
require "cloudflare/email/tenancy"

ROUTING_TENANT_ROOT = Dir.mktmpdir("cloudflare-routing-tenants")
Minitest.after_run do
  ActiveRecord::Base.connection_handler.clear_all_connections!
  FileUtils.remove_entry(ROUTING_TENANT_ROOT)
end

class RoutingTenantRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to shards: %i[organization _system_outbound].to_h { |key|
    [key, {writing: {adapter: "sqlite3", database: File.join(ROUTING_TENANT_ROOT, "#{key}.sqlite3")}}]
  }
end
Cloudflare::Email::Tenancy.configure(base_class: RoutingTenantRecord,
  switch: ->(key, &block) { RoutingTenantRecord.connected_to(role: :writing, shard: key.to_sym, &block) },
  current: -> { RoutingTenantRecord.current_shard.to_s })
require "cloudflare/email/active_record/routing_deliveries"
require "generators/cloudflare/email/outbox/templates/create_cloudflare_email_outbox"
require "generators/cloudflare/email/routing_tracking/templates/create_cloudflare_email_routing_delivery_receipts"
ActiveRecord::Encryption.configure(primary_key: "test-primary", deterministic_key: "test-deterministic", key_derivation_salt: "test-salt")
ActiveRecord::Migration.verbose = false
%w[organization _system_outbound].each do |key|
  Cloudflare::Email::Tenancy.with(key) do
    CreateCloudflareEmailOutbox.new.exec_migration(RoutingTenantRecord.connection, :up)
    CreateCloudflareEmailRoutingDeliveryReceipts.new.exec_migration(RoutingTenantRecord.connection, :up)
  end
end

class RoutingTenantsTest < Minitest::Test
  Tenancy = Cloudflare::Email::Tenancy
  API = Cloudflare::Email::ActiveRecord::RoutingDeliveries
  Receipt = Cloudflare::Email::ActiveRecord::RoutingDeliveryReceipt
  Outbox = Cloudflare::Email::ActiveRecord::Outbox

  def setup
    %w[organization _system_outbound].each do |key|
      Tenancy.with(key) do
        Receipt.delete_all
        Cloudflare::Email::ActiveRecord::OutboundRecipient.delete_all
        Cloudflare::Email::ActiveRecord::OutboundDelivery.delete_all
      end
    end
  end

  def record
    now = Time.at(Time.now.to_i - 30).utc
    delivery = Outbox.prepare(account_id: ACCOUNT_ID, operation_key: "same-operation", from: "sender@example.com",
      recipients: ["receiver@example.com"], mime_message: "Subject: test\r\n\r\nbody")
    delivery.update!(state: "accepted", provider_message_id: "same-message", request_started_at: now)
    delivery.outbound_recipients.update_all(state: "queued", acceptance_state: "accepted")
    row = {"messageId" => "same-message", "sessionId" => "same-session", "datetime" => now.iso8601,
      "eventType" => "newEmail", "status" => "delivered", "isNDR" => 0, "isLastEvent" => 1,
      "sampleInterval" => 1, "from" => "sender@example.com"}
    evidence = Cloudflare::Email::RoutingAnalytics::Evidence.new("source" => "cloudflare_routing_analytics",
      "account_id" => ACCOUNT_ID, "zone_id" => "a" * 32, "query_started_at" => now.iso8601,
      "query_finished_at" => (now + 10).iso8601, "event" => row,
      "response" => {"data" => {"viewer" => {"zones" => [{"zoneTag" => "a" * 32, "emailRoutingAdaptive" => [row]}]}}})
    API.record(delivery: delivery, evidence: evidence)
  end

  def test_receipts_are_isolated_and_instances_cannot_cross_contexts
    organization = Tenancy.with("organization") { record }
    Tenancy.with("_system_outbound") do
      assert_equal 0, Receipt.count
      system = record
      assert_equal organization.id, system.id
      assert_raises(Cloudflare::Email::ConfigurationError) { API.apply(organization) }
      assert_equal "pending", system.reload.state
      assert_equal :applied, API.apply(system)
    end
    Tenancy.with("organization") do
      assert_equal "pending", organization.reload.state
      assert_equal :applied, API.apply(organization)
    end
    assert_raises(Cloudflare::Email::ActiveRecord::TenantConnectionUnavailable) { Receipt.count }
  end
end
