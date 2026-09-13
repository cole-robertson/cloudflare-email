require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "active_record"
require "active_job"
require "global_id"
require "mailbox-kit"
require "mailbox_kit/tenancy"

CORE_TENANT_ROOT = Dir.mktmpdir("mailbox-kit-tenants")
Minitest.after_run do
  ActiveRecord::Base.connection_handler.clear_all_connections!
  FileUtils.remove_entry(CORE_TENANT_ROOT)
end
class CoreTenantRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to shards: %i[alpha beta].to_h { |key|
    [key, { writing: { adapter: "sqlite3", database: File.join(CORE_TENANT_ROOT, "#{key}.sqlite3") } }]
  }
end
MailboxKit::Tenancy.configure(base_class: CoreTenantRecord,
  switch: ->(key, &block) { CoreTenantRecord.connected_to(role: :writing, shard: key.to_sym, &block) },
  current: -> { CoreTenantRecord.current_shard.to_s })
require "mailbox_kit/active_record/base"
require "mailbox_kit/tenant_job_context"
GlobalID.app = "mailbox-kit-test"
ActiveJob::Base.logger = Logger.new(File::NULL)

class CoreOwnedRecord < MailboxKit::ActiveRecord::Base
  include GlobalID::Identification
  self.table_name = "owned_records"
end
class CoreCaptureJob < ActiveJob::Base
  prepend MailboxKit::TenantJobContext
  class_attribute :observations, default: []
  def perform(record)
    self.class.observations += [[MailboxKit::Tenancy.require_context!, record.name]]
  end
end
%w[alpha beta].each do |key|
  MailboxKit::Tenancy.with(key) do
    CoreTenantRecord.connection.create_table(:owned_records) { |table| table.string :name }
    CoreOwnedRecord.create!(id: 42, name: key)
  end
end
abort "core loaded Cloudflare adapter" if $LOADED_FEATURES.any? { |path| path.end_with?("/cloudflare-email.rb", "/cloudflare/email/client.rb") }

class CoreTenantContextTest < Minitest::Test
  Tenancy = MailboxKit::Tenancy
  def payload
    Tenancy.with("alpha") { CoreCaptureJob.new(CoreOwnedRecord.find(42)).serialize }
  end

  def test_job_resolves_same_id_in_original_tenant_and_restores_ambient_context
    data = payload
    CoreCaptureJob.observations = []
    Tenancy.with("beta") do
      ActiveJob::Base.execute(data)
      assert_equal "beta", Tenancy.require_context!
    end
    assert_equal [["alpha", "alpha"]], CoreCaptureJob.observations
    assert_nil Tenancy.current_key
  end

  def test_missing_or_conflicting_tenant_never_uses_ambient_database
    data = payload
    data.delete(MailboxKit::TenantJobContext::PAYLOAD_KEY)
    Tenancy.with("beta") do
      assert_raises(MailboxKit::ConfigurationError) { ActiveJob::Base.execute(data) }
      assert_equal "beta", Tenancy.require_context!
    end
    data = payload.merge("tenant" => "beta")
    assert_raises(MailboxKit::ConfigurationError) { ActiveJob::Base.execute(data) }
    assert_nil Tenancy.current_key
  end

  def test_models_reject_missing_context_and_stale_cross_tenant_records
    assert_raises(MailboxKit::ActiveRecord::TenantConnectionUnavailable) { CoreOwnedRecord.count }
    record = Tenancy.with("alpha") { CoreOwnedRecord.find(42) }
    Tenancy.with("beta") do
      assert_raises(MailboxKit::ConfigurationError) { record.update_columns(name: "wrong") }
      assert_equal "beta", CoreOwnedRecord.find(42).name
    end
  end
end
