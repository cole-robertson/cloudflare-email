require_relative "../test_helper"
require "tmpdir"
require "fileutils"
require "active_record"
require "cloudflare/email/tenancy"

TENANT_TEST_ROOT = Dir.mktmpdir("cloudflare-email-tenancy")
Minitest.after_run do
  ActiveRecord::Base.connection_handler.clear_all_connections!
  FileUtils.remove_entry(TENANT_TEST_ROOT)
end

class TenantRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to shards: %i[alpha beta].to_h { |key|
    [key, {writing: {adapter: "sqlite3", database: File.join(TENANT_TEST_ROOT, "#{key}.sqlite3")}}]
  }
end

Cloudflare::Email::Tenancy.configure(
  base_class: TenantRecord,
  switch: ->(key, &block) { TenantRecord.connected_to(role: :writing, shard: key.to_sym, &block) },
  current: -> { TenantRecord.current_shard.to_s },
)
require "cloudflare/email/active_record/event_receipt"
require "cloudflare/email/active_record/outbound_delivery"
require "cloudflare/email/active_record/outbound_recipient"
require "cloudflare/email/active_record/outbound_reconciliation"
require "active_job"
require "global_id"
require "cloudflare/email/tenant_job_context"

GlobalID.app = "cloudflare-email-tenancy-test"
Cloudflare::Email::ActiveRecord::EventReceipt.include(GlobalID::Identification)
ActiveJob::Base.logger = Logger.new(File::NULL)

class TenantReceiptJob < ActiveJob::Base
  prepend Cloudflare::Email::TenantJobContext
  class_attribute :observed, default: []

  def deserialize(data)
    super
    # Emulates a host integration that eagerly resolves records during deserialize.
    self.class.observed += [GlobalID::Locator.locate(data.fetch("arguments").first.fetch("_aj_globalid")).state]
  end

  def perform(receipt, fail_job = false)
    self.class.observed += [[Cloudflare::Email::Tenancy.require_context!, receipt.state]]
    raise "job failure" if fail_job
  end
end

module ActiveStorage
  class AnalyzeJob < TenantReceiptJob
  end
end
Cloudflare::Email::TenantJobContext.install_framework_jobs!

%w[alpha beta].each do |key|
  Cloudflare::Email::Tenancy.with(key) do
    TenantRecord.connection.create_table(:cloudflare_email_event_receipts) do |t|
      t.string :account_id
      t.string :event_id
      t.string :message_id
      t.text :payload_json
      t.string :state
    end
  end
end

class TenantFoundationTest < Minitest::Test
  Tenancy = Cloudflare::Email::Tenancy
  Receipt = Cloudflare::Email::ActiveRecord::EventReceipt

  def setup
    %w[alpha beta].each { |key| Tenancy.with(key) { Receipt.delete_all } }
  end

  def test_isolates_overlapping_ids_and_records
    alpha = Tenancy.with("alpha") { Receipt.create!(id: 42, account_id: "shared", event_id: "same", state: "alpha") }
    Tenancy.with("beta") do
      Receipt.create!(id: 42, account_id: "shared", event_id: "same", state: "beta")
      assert_equal "beta", Receipt.find(42).state
      assert_raises(Cloudflare::Email::ConfigurationError) { alpha.reload }
      assert_raises(Cloudflare::Email::ConfigurationError) { alpha.update!(state: "wrong") }
      assert_raises(Cloudflare::Email::ConfigurationError) { alpha.update_columns(state: "wrong") }
      assert_raises(Cloudflare::Email::ConfigurationError) { alpha.delete }
      assert_equal "beta", Receipt.find(42).state
    end
    Tenancy.with("alpha") { assert_equal "alpha", alpha.reload.state }
  end

  def test_requires_explicit_context_even_if_host_defaults_to_a_tenant
    assert_raises(Cloudflare::Email::ConfigurationError) { Receipt.count }
    assert_raises(Cloudflare::Email::ConfigurationError) { Receipt.new }
    assert_raises(Cloudflare::Email::ConfigurationError) { Tenancy.require_context! }
  end

  def test_nested_exception_restores_host_and_gem_context
    original_shard = TenantRecord.current_shard
    Tenancy.with("alpha") do
      assert_raises(RuntimeError) do
        Tenancy.with("beta") do
          assert_equal "beta", Tenancy.require_context!
          assert_equal :beta, TenantRecord.current_shard
          raise "intentional rollback"
        end
      end
      assert_equal "alpha", Tenancy.require_context!
      assert_equal :alpha, TenantRecord.current_shard
    end
    assert_nil Tenancy.current_key
    assert_equal original_shard, TenantRecord.current_shard
  end

  def test_host_switch_cannot_silently_override_selected_tenant
    Tenancy.with("alpha") do
      TenantRecord.connected_to(role: :writing, shard: :beta) do
        assert_raises(Cloudflare::Email::ConfigurationError) { Receipt.count }
      end
    end
  end

  def test_all_durable_models_use_host_connection_owner
    %i[EventReceipt OutboundDelivery OutboundRecipient OutboundReconciliation].each do |name|
      klass = Cloudflare::Email::ActiveRecord.const_get(name)
      assert klass < TenantRecord
      assert_raises(Cloudflare::Email::ConfigurationError) { klass.connection_pool }
    end
  end

  def test_rejects_ambiguous_keys_and_late_configuration
    [nil, "", " ", "alpha ", "alpha\n", :alpha, 123].each do |key|
      assert_raises(Cloudflare::Email::ConfigurationError) { Tenancy.with(key) {} }
    end
    assert_raises(Cloudflare::Email::ConfigurationError) do
      Tenancy.configure(base_class: TenantRecord, switch: -> {}, current: -> {})
    end
  end

  def job_payload(fail_job: false)
    Tenancy.with("beta") { Receipt.create!(id: 42, state: "beta") }
    Tenancy.with("alpha") do
      receipt = Receipt.create!(id: 42, state: "alpha")
      TenantReceiptJob.new(receipt, fail_job).serialize
    end
  end

  def test_job_selects_tenant_before_deserialize_and_global_id_lookup
    payload = job_payload
    TenantReceiptJob.observed = []
    Tenancy.with("beta") do
      ActiveJob::Base.execute(payload)
      assert_equal "beta", Tenancy.require_context!
    end
    assert_equal ["alpha", ["alpha", "alpha"]], TenantReceiptJob.observed
    assert_nil Tenancy.current_key
  end

  def test_job_failure_restores_context_and_reserialization_retains_tenant
    payload = job_payload(fail_job: true)
    job = ActiveJob::Base.deserialize(payload)
    Tenancy.with("beta") do
      assert_equal "alpha", job.serialize.fetch(Cloudflare::Email::TenantJobContext::PAYLOAD_KEY)
      assert_raises(RuntimeError) { job.perform_now }
      assert_equal "beta", Tenancy.require_context!
    end
    assert_nil Tenancy.current_key
  end

  def test_job_missing_tenant_does_not_fall_back_to_ambient_context
    payload = job_payload
    payload.delete(Cloudflare::Email::TenantJobContext::PAYLOAD_KEY)
    Tenancy.with("beta") do
      assert_raises(Cloudflare::Email::ConfigurationError) { ActiveJob::Base.execute(payload) }
    end
    assert_raises(Cloudflare::Email::ConfigurationError) { TenantReceiptJob.new.serialize }
    assert_raises(Cloudflare::Email::ConfigurationError) { TenantReceiptJob.new.perform_now }
  end

  def test_job_rejects_conflicting_native_tenant_metadata
    payload = job_payload
    payload["tenant"] = "beta"
    assert_raises(Cloudflare::Email::ConfigurationError) { ActiveJob::Base.execute(payload) }
    assert_nil Tenancy.current_key
  end

  def test_framework_job_captures_trusted_host_only_context
    receipt = Tenancy.with("alpha") { Receipt.create!(id: 42, state: "alpha") }
    Tenancy.with("beta") { Receipt.create!(id: 42, state: "beta") }
    payload = TenantRecord.connected_to(role: :writing, shard: :alpha) do
      assert_nil Tenancy.current_key
      assert_equal "alpha", Tenancy.host_current_key
      ActiveStorage::AnalyzeJob.new(receipt).serialize
    end
    assert_equal "alpha", payload.fetch(Cloudflare::Email::TenantJobContext::PAYLOAD_KEY)
    assert_nil Tenancy.current_key
    ActiveStorage::AnalyzeJob.observed = []
    TenantRecord.connected_to(role: :writing, shard: :beta) do
      ActiveJob::Base.execute(payload)
      assert_equal :beta, TenantRecord.current_shard
      assert_nil Tenancy.current_key
    end
    assert_equal ["alpha", ["alpha", "alpha"]], ActiveStorage::AnalyzeJob.observed

    payload.delete(Cloudflare::Email::TenantJobContext::PAYLOAD_KEY)
    TenantRecord.connected_to(role: :writing, shard: :alpha) do
      assert_raises(Cloudflare::Email::ConfigurationError) { ActiveJob::Base.execute(payload) }
    end
  end
end
