# Fresh process: real production Rails boot, including AR's attribute preloader.
ENV["RAILS_ENV"] = "production"
require "tmpdir"
require "fileutils"
require "minitest/autorun"
require "rails"
require "active_record/railtie"

GEM_ROOT = ENV.fetch("CLOUDFLARE_EMAIL_TEST_GEM_ROOT") { File.expand_path("../..", __dir__) }
$LOAD_PATH.unshift File.join(GEM_ROOT, "lib")
require "cloudflare-email"
require "cloudflare/email/tenancy"

APP_ROOT = Dir.mktmpdir("cloudflare-email-production-tenancy")
FileUtils.mkdir_p("#{APP_ROOT}/config")
File.write("#{APP_ROOT}/config/database.yml", <<~YAML)
  production:
    adapter: sqlite3
    database: #{APP_ROOT}/shared.sqlite3
YAML
Minitest.after_run do
  ActiveRecord::Base.connection_handler.clear_all_connections!
  FileUtils.remove_entry(APP_ROOT)
end

class ProductionTenantApp < Rails::Application
  config.root = APP_ROOT
  config.eager_load = true
  config.enable_reloading = false
  config.secret_key_base = "a" * 64
  config.logger = Logger.new(File::NULL)
  # Rails 8.1's production attribute preloader deliberately asks each
  # descendant for its pool here, outside any tenant/request context.
  config.active_record.check_schema_cache_dump_version = false

  initializer "configure_test_tenancy", after: "active_record.initialize_database" do
    class ::ProductionTenantRecord < ActiveRecord::Base
      self.abstract_class = true
      connects_to shards: %i[alpha beta].to_h { |key|
        [key, {writing: {adapter: "sqlite3", database: "#{APP_ROOT}/#{key}.sqlite3"}}]
      }
    end
    Cloudflare::Email::Tenancy.configure(
      base_class: ProductionTenantRecord,
      switch: ->(key, &block) { ProductionTenantRecord.connected_to(role: :writing, shard: key.to_sym, &block) },
      current: -> { ProductionTenantRecord.current_shard.to_s },
    )
    require "cloudflare/email/active_record/event_receipt"
    %w[alpha beta].each do |key|
      Cloudflare::Email::Tenancy.with(key) do
        ProductionTenantRecord.connection.create_table(:cloudflare_email_event_receipts) do |t|
          t.string :state
        end
      end
    end
  end
end

ProductionTenantApp.initialize!

class ProductionTenantBootTest < Minitest::Test
  Tenancy = Cloudflare::Email::Tenancy
  Receipt = Cloudflare::Email::ActiveRecord::EventReceipt
  PoolError = Cloudflare::Email::ActiveRecord::TenantConnectionUnavailable

  def test_boot_keeps_pool_and_query_access_closed_without_context
    assert Rails.env.production?
    assert Rails.application.config.eager_load
    refute Rails.application.config.active_record.check_schema_cache_dump_version
    assert_nil Tenancy.current_key
    error = assert_raises(PoolError) { Receipt.connection_pool }
    assert_kind_of ActiveRecord::ActiveRecordError, error
    assert_kind_of Cloudflare::Email::ConfigurationError, error.cause
    ProductionTenantRecord.connected_to(role: :writing, shard: :alpha) do
      assert_raises(PoolError) { Receipt.count }
    end
  end

  def test_explicit_context_works_and_mismatched_host_still_fails
    %w[alpha beta].each do |key|
      Tenancy.with(key) do
        Receipt.delete_all
        Receipt.create!(id: 1, state: key)
      end
    end
    Tenancy.with("alpha") do
      assert_equal "alpha", Receipt.find(1).state
      ProductionTenantRecord.connected_to(role: :writing, shard: :beta) do
        error = assert_raises(PoolError) { Receipt.count }
        assert_match(/does not match/, error.message)
      end
    end
    Tenancy.with("beta") { assert_equal "beta", Receipt.find(1).state }
    assert_nil Tenancy.current_key
  end
end
