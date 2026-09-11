require "test_helper"
require "open3"
require "rbconfig"

class ManagementEngineTest < Minitest::Test
  def test_base_client_does_not_load_the_management_engine
    script = 'require "cloudflare-email"; abort "management loaded by default" if defined?(Cloudflare::Email::Management)'
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", script)
    assert status.success?, output
  end

  def test_mounted_management_with_real_rails_sessions
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", File.expand_path("support/management_engine.rb", __dir__))
    assert status.success?, output
  end

  def test_core_engine_eager_load_does_not_expose_management
    script = <<~RUBY
      require "tmpdir"
      require "fileutils"
      require "rails"
      require "action_controller/railtie"
      require "cloudflare-email"
      require "cloudflare/email/engine"
      require "rack/mock"
      fixture_root = Dir.mktmpdir("cf-email-no-management")
      ENV["RAILS_ENV"] = "test"
      ENV["CF_MANAGEMENT_FIXTURE_ROOT"] = fixture_root
      class CoreOnlyFixture < Rails::Application
        config.root = ENV.fetch("CF_MANAGEMENT_FIXTURE_ROOT")
        config.eager_load = true
        config.enable_reloading = false
        config.secret_key_base = "c" * 64
        config.hosts.clear
        config.logger = Logger.new(File::NULL)
      end
      begin
        CoreOnlyFixture.initialize!
        abort "management loaded without opt-in" if defined?(Cloudflare::Email::Management)
        response = Rack::MockRequest.new(Rails.application).get("/email/mailboxes")
        abort "management path exposed" unless response.status == 404
      ensure
        FileUtils.remove_entry(fixture_root)
      end
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", script)
    assert status.success?, output
  end

  def test_management_templates_are_packaged
    specification = Gem::Specification.load(File.expand_path("../cloudflare-email.gemspec", __dir__))
    templates = Dir["app/views/cloudflare/email/management/**/*.erb", "app/views/layouts/cloudflare/email/management.html.erb",
      "lib/cloudflare/email/management/*.css"]
    refute_empty templates
    assert_empty templates - specification.files
  end
end
