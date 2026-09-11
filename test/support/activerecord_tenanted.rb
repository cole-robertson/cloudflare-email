ENV["RAILS_ENV"] = "test"
require "tmpdir"
require "fileutils"
require "yaml"
require "minitest/autorun"
require "rails/all"
require "activerecord-tenanted"

TENANTED_ROOT = Dir.mktmpdir("cf-actual-tenanted")
GEM_SOURCE = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift File.join(GEM_SOURCE, "lib")
require "cloudflare-email"
require "cloudflare/email/tenancy"
require "cloudflare/email/mailboxes/configuration"
Minitest.after_run { FileUtils.remove_entry(TENANTED_ROOT) }
FileUtils.mkdir_p(File.join(TENANTED_ROOT, "config"))
FileUtils.mkdir_p(File.join(TENANTED_ROOT, "db/tenant_migrate"))
File.write(File.join(TENANTED_ROOT, "config/database.yml"), {
  "test" => {
    "primary" => { "adapter" => "sqlite3", "database" => File.join(TENANTED_ROOT, "directory.sqlite3") },
    "tenant" => { "adapter" => "sqlite3", "database" => File.join(TENANTED_ROOT, "tenants/%{tenant}/db.sqlite3"),
      "tenanted" => true, "migrations_paths" => File.join(TENANTED_ROOT, "db/tenant_migrate") }
  }
}.to_yaml)
%w[outbox/templates/create_cloudflare_email_outbox.rb tracking/templates/create_cloudflare_email_event_receipts.rb mailboxes/templates/create_cloudflare_email_mailboxes.rb].each_with_index do |source, index|
  FileUtils.cp(File.join(GEM_SOURCE, "lib/generators/cloudflare/email", source),
    File.join(TENANTED_ROOT, "db/tenant_migrate", "2026091200000#{index}_#{File.basename(source)}"))
end

class ActualTenantedApp < Rails::Application
  config.root = TENANTED_ROOT
  config.eager_load = false
  config.secret_key_base = "x" * 64
  config.logger = Logger.new(File::NULL)
  config.active_record_tenanted.connection_class = "TenantRecord"
  config.active_record_tenanted.tenanted_rails_records = false
  config.active_record_tenanted.log_tenant_tag = false
  config.active_job.queue_adapter = :test
  config.active_storage.service = :test
  config.active_storage.service_configurations = { "test" => { "service" => "Disk", "root" => File.join(TENANTED_ROOT, "storage") } }
  initializer "cloudflare_test.configure_tenant_models",
      after: "active_record_tenanted.active_record_base", before: :load_config_initializers do
    # Non-autoloaded bases: the optional gem retains these class identities.
    Object.const_set(:TenantRecord, Class.new(ActiveRecord::Base) do
      self.abstract_class = true
    end)
    TenantRecord.tenanted "tenant"
    Object.const_set(:DirectoryRecord, Class.new(ActiveRecord::Base) do
      self.abstract_class = true
    end)
    DirectoryRecord.connects_to database: { writing: :primary }
    Cloudflare::Email::Tenancy.configure(base_class: TenantRecord,
      current: -> { TenantRecord.current_tenant },
      switch: ->(key, &block) {
        raise Cloudflare::Email::Mailboxes::Unavailable, "tenant is not provisioned" unless TenantRecord.tenant_exist?(key)
        TenantRecord.with_tenant(key, &block)
      })
    Cloudflare::Email::Mailboxes.configure(directory_base: DirectoryRecord)
    require "cloudflare/email/mailboxes"
  end
end
ActualTenantedApp.initialize!
ActiveRecord::Migration.verbose = false
require "generators/cloudflare/email/mailboxes/templates/create_cloudflare_email_receiving_domains"
require "generators/cloudflare/email/mailboxes/templates/create_cloudflare_email_shared_events"
CreateCloudflareEmailReceivingDomains.new.migrate(:up)
CreateCloudflareEmailSharedEvents.new.migrate(:up)
%w[alpha beta].each { |key| TenantRecord.create_tenant(key) }

class ActualTenantedMailboxTest < Minitest::Test
  Mailboxes = Cloudflare::Email::Mailboxes
  Tenancy = Cloudflare::Email::Tenancy

  def setup
    Mailboxes::ReceivingDomain.delete_all
    %w[alpha beta].each do |key|
      Mailboxes::ReceivingDomain.create!(domain: "#{key}.example.com", tenant_key: key, account_id: "account", state: "active")
      Tenancy.with(key) { Mailboxes::Mailbox.delete_all }
    end
  end

  def test_actual_library_isolates_same_numeric_ids_and_restores_context
    records = %w[alpha beta].map do |key|
      Tenancy.with(key) do
        mailbox = Mailboxes::Mailbox.create!(name: key, tenant_key: key, state: "active")
        assert_equal key, mailbox.tenant
        assert_equal key, TenantRecord.current_tenant
        assert_equal [key], Mailboxes::Mailbox.pluck(:name)
        mailbox
      end
    end
    assert_equal records[0].id, records[1].id
    assert_nil TenantRecord.current_tenant
    assert_nil Tenancy.current_key
    Tenancy.with("beta") do
      assert_raises(Cloudflare::Email::ConfigurationError) { records[0].reload }
    end
    assert_raises(Cloudflare::Email::ConfigurationError) { Mailboxes::Mailbox.count }
    assert_raises(RuntimeError) { Tenancy.with("alpha") { raise "callback failed" } }
    assert_nil TenantRecord.current_tenant
    assert_nil Tenancy.current_key
  end

  def test_unknown_tenant_does_not_create_database
    refute TenantRecord.tenant_exist?("unknown")
    assert_raises(Mailboxes::Unavailable) { Tenancy.with("unknown") { Mailboxes::Mailbox.count } }
    refute File.exist?(File.join(TENANTED_ROOT, "tenants/unknown/db.sqlite3"))
    assert_nil TenantRecord.current_tenant
  end

  def test_global_id_requires_matching_explicit_tenant_context
    gid = Tenancy.with("alpha") do
      record = Mailboxes::Mailbox.create!(name: "GlobalID", tenant_key: "alpha", state: "active")
      record.to_global_id
    end
    assert_equal "alpha", gid.tenant
    assert_raises(ActiveRecord::Tenanted::NoTenantError) { GlobalID::Locator.locate(gid) }
    Tenancy.with("beta") do
      assert_raises(ActiveRecord::Tenanted::WrongTenantError) { GlobalID::Locator.locate(gid) }
    end
    Tenancy.with("alpha") do
      assert_equal "GlobalID", GlobalID::Locator.locate(gid).name
      without_tenant = gid.to_s.split("?", 2).first
      assert_raises(ActiveRecord::Tenanted::MissingTenantError) { GlobalID::Locator.locate(without_tenant) }
    end
  end
end
