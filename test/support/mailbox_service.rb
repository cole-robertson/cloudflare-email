require_relative "../test_helper"
require "tmpdir"
require "fileutils"
require "active_record"
require "mail"
require "minitest/mock"
require "cloudflare/email/tenancy"
require "cloudflare/email/mailboxes/configuration"

SERVICE_ROOT = Dir.mktmpdir("cf-mailbox-service")
Minitest.after_run do
  ActiveRecord::Base.connection_handler.clear_all_connections!
  FileUtils.remove_entry(SERVICE_ROOT)
end
class ServiceDirectoryRecord < ActiveRecord::Base
  self.abstract_class = true
  establish_connection adapter: "sqlite3", database: File.join(SERVICE_ROOT, "directory.sqlite3")
end
class ServiceTenantRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to shards: %i[alpha beta].to_h { |key|
    [key, { writing: { adapter: "sqlite3", database: File.join(SERVICE_ROOT, "#{key}.sqlite3") } }]
  }
end
Cloudflare::Email::Tenancy.configure(base_class: ServiceTenantRecord,
  switch: ->(key, &block) { ServiceTenantRecord.connected_to(role: :writing, shard: key.to_sym, &block) },
  current: -> { ServiceTenantRecord.current_shard.to_s })
SERVICE_CLIENTS = {}
Cloudflare::Email::Mailboxes.configure(directory_base: ServiceDirectoryRecord,
  client_resolver: ->(tenant, account) { SERVICE_CLIENTS.fetch(tenant) })
require "cloudflare/email/mailboxes"
require "generators/cloudflare/email/mailboxes/templates/create_cloudflare_email_receiving_domains"
require "generators/cloudflare/email/mailboxes/templates/create_cloudflare_email_shared_events"
require "generators/cloudflare/email/mailboxes/templates/create_cloudflare_email_mailboxes"
require "generators/cloudflare/email/outbox/templates/create_cloudflare_email_outbox"
require "generators/cloudflare/email/tracking/templates/create_cloudflare_email_event_receipts"
ActiveRecord::Migration.verbose = false
# Establish Base only during fixture installation; requests use fixed shard pools.
ActiveRecord::Base.establish_connection(ServiceDirectoryRecord.connection_db_config.configuration_hash)
CreateCloudflareEmailReceivingDomains.new.migrate(:up)
CreateCloudflareEmailSharedEvents.new.migrate(:up)
%w[alpha beta].each do |key|
  Cloudflare::Email::Tenancy.with(key) do
    ActiveRecord::Base.establish_connection(ServiceTenantRecord.connection_db_config.configuration_hash)
    CreateCloudflareEmailOutbox.new.migrate(:up)
    CreateCloudflareEmailEventReceipts.new.migrate(:up)
    CreateCloudflareEmailMailboxes.new.migrate(:up)
  end
end
ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(File::NULL)

class MailboxServiceIntegrationTest < Minitest::Test
  Email = Cloudflare::Email
  Box = Email::Mailboxes
  Delivery = Email::ActiveRecord::OutboundDelivery
  ENDPOINT = "https://api.cloudflare.com/client/v4/accounts/shared/email/sending/send_raw"

  def setup
    Box::ProviderCorrelation.delete_all
    Box::SharedEventReceipt.delete_all
    Box::ReceivingDomain.delete_all
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    @ids = {}
    %w[alpha beta].each do |key|
      SERVICE_CLIENTS[key] = Email::Client.new(account_id: "shared", api_token: "test-token", retries: 0, retry_ambiguous: false)
      Box.for_tenant(key) do |session|
        [Box::OutboundMessage, Box::Message, Box::Address, Box::Mailbox,
          Email::ActiveRecord::EventReceipt, Email::ActiveRecord::OutboundReconciliation,
          Email::ActiveRecord::OutboundRecipient, Delivery].each(&:delete_all)
        ServiceTenantRecord.connection.execute("DELETE FROM sqlite_sequence WHERE name = 'cloudflare_email_mailboxes'")
        ServiceTenantRecord.connection.execute("INSERT INTO sqlite_sequence(name, seq) VALUES ('cloudflare_email_mailboxes', 41)")
        domain = Box.register_domain(domain: "#{key}.example.com", tenant_key: key, account_id: "shared")
        Box.activate_domain!(domain.id, evidence: "operator verified DNS and sending", sending_enabled: true)
        mailbox = session.create(name: "Support", address: "Support@#{key}.example.com", owner_ref: "customer:42")
        @ids[key] = mailbox.id
        session.activate_address!(mailbox.addresses.first.id, evidence: "route verified")
      end
    end
  end

  def mail(key = "alpha", from: nil)
    Mail.new do
      from(from || "support@#{key}.example.com")
      to "reader@example.net"
      subject "Hello"
      body "Saved mailbox message"
      date Time.utc(2026, 9, 11)
      message_id "fixed-#{key}@example.com"
    end
  end

  def provider_success
    stub_request(:post, ENDPOINT).to_return(status: 200, headers: { "Content-Type" => "application/json" },
      body: JSON.generate(success: true, result: { message_id: "provider-123" }))
  end

  def test_directory_and_address_lifecycle_and_owner_reference
    pending = Box.register_domain(domain: "NEW.Example.com", tenant_key: "alpha", account_id: "shared")
    assert_equal "pending", pending.state
    assert_equal "new.example.com", pending.domain
    assert_raises(ArgumentError) { Box.activate_domain!(pending.id, evidence: " ") }
    Box.for_tenant("alpha") do |session|
      assert_equal "customer:42", session.mailboxes.find(42).owner_ref
      assert_raises(ActiveRecord::RecordNotFound) { session.add_address(42, address: "new@new.example.com") }
      address = session.add_address(42, address: "ALIAS@alpha.example.com")
      assert_equal "pending", address.state
      session.activate_address!(address.id, evidence: "individual route activated")
      assert_equal "active", address.reload.state
      session.suspend(42)
      assert_raises(ActiveRecord::RecordNotFound) { session.add_address(42, address: "other@alpha.example.com") }
      session.resume(42)
      assert_equal "active", session.mailboxes.find(42).state
    end
  end

  def test_receive_alias_deduplication_and_read_archive
    Box.for_tenant("alpha") do |session|
      address = session.add_address(42, address: "alias@alpha.example.com")
      session.activate_address!(address.id, evidence: "route verified")
    end
    inbound = Struct.new(:id).new(100)
    assert_equal inbound, Box.receive(recipient: "support@alpha.example.com") { inbound }
    Box.receive(recipient: "alias@alpha.example.com") { inbound }
    Box.for_tenant("alpha") do |session|
      assert_equal 1, session.messages(42).count
      id = session.messages(42).first.id
      session.mark_read(42, id)
      session.archive(42, id)
      assert_equal 0, session.messages(42).inbox.unread.count
      session.mark_read(42, id, read: false)
      session.archive(42, id, archived: false)
      assert_equal 1, session.messages(42).inbox.unread.count
    end
    Box.for_tenant("beta") { |session| assert_equal 0, session.messages(42).count }
    assert_raises(Box::Unavailable) { Box.receive(recipient: "unknown@alpha.example.com") { flunk "stored unknown mail" } }
  end

  def test_overlapping_ids_and_operation_names_remain_isolated
    keys = %w[alpha beta].map do |key|
      Box.for_tenant(key) do |session|
        delivery = session.prepare(42, operation_key: "same-operation", mail: mail(key))
        repeated = session.prepare(42, operation_key: "same-operation", mail: mail(key))
        assert_equal delivery.id, repeated.id
        assert_equal 1, Box::OutboundMessage.count
        assert_equal "support@#{key}.example.com", delivery.from_address
        delivery.operation_key
      end
    end
    refute_equal keys.first, keys.last
    Box.for_tenant("beta") do |session|
      assert_raises(ActiveRecord::RecordNotFound) { session.enqueue(42, operation_key: keys.first) }
    end
    escaped = Box.for_tenant("alpha") { |session| session }
    assert_raises(Email::ConfigurationError) { escaped.mailboxes }
  end

  def test_prepare_requires_owned_active_sender_and_send_enabled_domain
    Box.for_tenant("alpha") do |session|
      assert_raises(ActiveRecord::RecordNotFound) { session.prepare(42, operation_key: "foreign", mail: mail("beta")) }
      spoofed = mail
      spoofed.sender = "elsewhere@example.net"
      assert_raises(Email::ValidationError) { session.prepare(42, operation_key: "spoofed", mail: spoofed) }
      Box::ReceivingDomain.find_by!(tenant_key: "alpha").update!(sending_enabled: false)
      assert_raises(Box::Unavailable) { session.prepare(42, operation_key: "disabled", mail: mail) }
      assert_equal 0, Delivery.count
    end
  end

  def test_identity_only_job_and_duplicate_execution_send_once
    request = provider_success
    job = Box.for_tenant("alpha") do |session|
      delivery = session.prepare(42, operation_key: "send", mail: mail)
      session.enqueue(42, operation_key: delivery.operation_key)
    end
    serialized = job.serialize
    assert_equal ["alpha", 42], serialized.fetch("arguments").first(2)
    assert_equal 3, serialized.fetch("arguments").length
    2.times { ActiveJob::Base.execute(serialized) }
    assert_requested request, times: 1
    assert_equal 1, Box::ProviderCorrelation.count
    Box.for_tenant("alpha") { assert_equal "accepted", Delivery.first.state }
    assert_nil Email::Tenancy.current_key
  end

  def test_suspended_queued_mailbox_and_mismatched_client_do_not_send
    job = Box.for_tenant("alpha") do |session|
      delivery = session.prepare(42, operation_key: "send", mail: mail)
      queued = session.enqueue(42, operation_key: delivery.operation_key)
      session.suspend(42)
      queued
    end
    assert_raises(ActiveRecord::RecordNotFound) { ActiveJob::Base.execute(job.serialize) }
    Box.for_tenant("alpha") do |session|
      session.resume(42)
      SERVICE_CLIENTS["alpha"] = Email::Client.new(account_id: "wrong", api_token: "token", retries: 0, retry_ambiguous: false)
      assert_raises(Email::ConfigurationError) { session.deliver(42, operation_key: Delivery.first.operation_key) }
      assert_equal "prepared", Delivery.first.state
    end
    assert_not_requested :post, ENDPOINT
  end

  def test_ambiguous_network_error_stays_unknown_without_resend
    request = stub_request(:post, ENDPOINT).to_timeout
    Box.for_tenant("alpha") do |session|
      delivery = session.prepare(42, operation_key: "uncertain", mail: mail)
      assert_raises(Email::NetworkError) { session.deliver(42, operation_key: delivery.operation_key) }
      assert_equal "unknown", delivery.reload.state
      assert_raises(Email::ActiveRecord::Outbox::InvalidTransition) { session.deliver(42, operation_key: delivery.operation_key) }
      session.recover
      assert_empty ActiveJob::Base.queue_adapter.enqueued_jobs
    end
    assert_requested request, times: 1
  end

  def test_recover_repairs_correlations_and_enqueue_gaps
    request = provider_success
    Box.for_tenant("alpha") do |session|
      first = session.prepare(42, operation_key: "first", mail: mail)
      session.deliver(42, operation_key: first.operation_key)
      Box::ProviderCorrelation.delete_all
      session.prepare(42, operation_key: "second", mail: mail)
      session.recover
      assert_equal 1, Box::ProviderCorrelation.count
      assert_equal 1, ActiveJob::Base.queue_adapter.enqueued_jobs.length
    end
    assert_requested request, times: 1
  end

  def test_failed_provisioning_keeps_alias_pending_and_retry_activates
    calls = []
    provisioner = Object.new
    provisioner.define_singleton_method(:provision) do |**options|
      calls << options
      raise "provider unavailable" if calls.length == 1
    end
    Box.for_tenant("alpha") do |session|
      address = session.add_address(42, address: "new@alpha.example.com")
      assert_raises(RuntimeError) { session.provision_address!(address.id, provisioner: provisioner, worker_name: "mail-worker") }
      assert_equal "pending", address.reload.state
      session.provision_address!(address.id, provisioner: provisioner, worker_name: "mail-worker")
      assert_equal "active", address.reload.state
      assert_equal({ address: "new@alpha.example.com", worker_name: "mail-worker" }, calls.first)
    end
  end

  def test_prepare_is_transactional_and_enqueue_must_follow_commit
    Box.for_tenant("alpha") do |session|
      Box::Mailbox.transaction do
        delivery = session.prepare(42, operation_key: "rolled-back", mail: mail)
        assert_raises(ArgumentError) { session.enqueue(42, operation_key: delivery.operation_key) }
        raise ActiveRecord::Rollback
      end
      assert_equal 0, Delivery.count
      assert_equal 0, Box::OutboundMessage.count
      assert_empty ActiveJob::Base.queue_adapter.enqueued_jobs
    end
  end

  def test_explicit_ambiguous_reconciliation_registers_provider_evidence
    stub_request(:post, ENDPOINT).to_timeout
    Box.for_tenant("alpha") do |session|
      delivery = session.prepare(42, operation_key: "reconciled", mail: mail)
      assert_raises(Email::NetworkError) { session.deliver(42, operation_key: delivery.operation_key) }
      session.reconcile(42, operation_key: delivery.operation_key, outcome: "accepted",
        actor: "operator:1", reason: "provider confirmed acceptance", evidence: "support ticket 123",
        provider_message_id: "confirmed-123", recipients: ["reader@example.net"])
      assert_equal "accepted", delivery.reload.state
      assert_equal "confirmed-123", Box::ProviderCorrelation.first.message_id
    end
  end

  def test_projection_failure_retries_without_resending_and_rolls_back_projection
    request = provider_success
    attempts = 0
    handler = lambda do |delivery|
      assert_equal "alpha", Email::Tenancy.require_context!
      assert delivery.class.connection.transaction_open?
      Box::Mailbox.find(42).update!(name: "Projected")
      attempts += 1
      raise "projection unavailable" if attempts == 1
    end
    Box.stub(:delivery_handler, -> { handler }) do
      Box.for_tenant("alpha") do |session|
        delivery = session.prepare(42, operation_key: "projection-retry", mail: mail)
        assert_raises(RuntimeError) { session.deliver(42, operation_key: delivery.operation_key) }
        assert_equal "accepted", delivery.reload.state
        assert_equal "Support", session.mailboxes.find(42).name
        assert_equal 0, Box::ProviderCorrelation.count
        session.deliver(42, operation_key: delivery.operation_key)
        assert_equal "Projected", session.mailboxes.find(42).name
        assert_equal 1, Box::ProviderCorrelation.count
      end
    end
    assert_equal 2, attempts
    assert_requested request, times: 1
  end

  def test_competing_send_claims_do_not_duplicate_network_delivery
    entered, release = Queue.new, Queue.new
    request = stub_request(:post, ENDPOINT).to_return do
      entered << true
      release.pop
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate(success: true, result: { message_id: "concurrent-provider" }) }
    end
    operation = Box.for_tenant("alpha") { |session| session.prepare(42, operation_key: "concurrent", mail: mail).operation_key }
    sender = Thread.new do
      Box.for_tenant("alpha") { |session| session.deliver(42, operation_key: operation) }
    end
    entered.pop
    Box.for_tenant("alpha") do |session|
      assert_raises(Email::ActiveRecord::Outbox::InvalidTransition) { session.deliver(42, operation_key: operation) }
    end
    release << true
    sender.value
    assert_requested request, times: 1
    Box.for_tenant("alpha") { assert_equal "accepted", Delivery.first.state }
  ensure
    release << true if release && sender&.alive?
    sender&.join
  end

  def test_reconciliation_block_failure_rolls_back_evidence_and_projection
    stub_request(:post, ENDPOINT).to_timeout
    Box.for_tenant("alpha") do |session|
      delivery = session.prepare(42, operation_key: "reconcile-projection", mail: mail)
      assert_raises(Email::NetworkError) { session.deliver(42, operation_key: delivery.operation_key) }
      assert_raises(RuntimeError) do
        session.reconcile(42, operation_key: delivery.operation_key, outcome: "accepted",
          actor: "operator:1", reason: "provider confirmed", evidence: "ticket",
          provider_message_id: "confirmed-456", recipients: ["reader@example.net"]) do |row|
          assert_equal delivery.id, row.id
          Box::Mailbox.find(42).update!(name: "Projected")
          raise "projection failed"
        end
      end
      assert_equal "unknown", delivery.reload.state
      assert_equal "Support", session.mailboxes.find(42).name
      assert_equal 0, Email::ActiveRecord::OutboundReconciliation.count
      assert_equal 0, Box::ProviderCorrelation.count
    end
  end

  def test_recovery_job_schedules_next_page_and_stops_at_empty_page
    Box.for_tenant("alpha") { |session| session.prepare(42, operation_key: "recover-page", mail: mail) }
    Box::RecoverJob.perform_now("alpha")
    queue = ActiveJob::Base.queue_adapter.enqueued_jobs
    assert_equal 1, queue.count { |job| job[:job] == Box::SendJob }
    continuation = queue.find { |job| job[:job] == Box::RecoverJob }
    refute_nil continuation
    assert_equal "alpha", continuation[:args].first
    assert_operator continuation[:args].last, :>, 0
    count = queue.length
    Box::RecoverJob.perform_now(*continuation[:args])
    assert_equal count, queue.length
  end

  def test_recovery_repairs_a_failed_delivery_projection_without_network_retry
    request = provider_success
    failed = ->(_delivery) { raise "projection failed" }
    Box.for_tenant("alpha") do |session|
      delivery = session.prepare(42, operation_key: "recover-projection", mail: mail)
      Box.stub(:delivery_handler, -> { failed }) do
        assert_raises(RuntimeError) { session.deliver(42, operation_key: delivery.operation_key) }
      end
      repaired = ->(_delivery) { Box::Mailbox.find(42).update!(name: "Recovered") }
      Box.stub(:delivery_handler, -> { repaired }) { session.recover }
      assert_equal "Recovered", session.mailboxes.find(42).name
      assert_equal 1, Box::ProviderCorrelation.count
      assert_empty ActiveJob::Base.queue_adapter.enqueued_jobs
    end
    assert_requested request, times: 1
  end
end
