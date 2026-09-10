# Run in a fresh process: Rails applications cannot be booted twice in one VM.
require "tmpdir"
require "fileutils"
require "minitest/autorun"
require "minitest/mock"
require "rails"
require "action_controller/railtie"
require "action_mailer/railtie"

INBOUND = ARGV.delete("inbound")
ARGV.delete("send_only")
if INBOUND
  require "active_record/railtie"
  require "active_job/railtie"
  require "active_storage/engine"
  require "action_mailbox/engine"
end
GEM_ROOT = ENV.fetch("CLOUDFLARE_EMAIL_TEST_GEM_ROOT") { File.expand_path("../..", __dir__) }
$LOAD_PATH.unshift File.join(GEM_ROOT, "lib")
require "cloudflare-email"
require "cloudflare/email/dev_tunnel"
require "generators/cloudflare/email/install_generator"
require "rack/test"

APP_ROOT = Dir.mktmpdir("cloudflare-email-rails")
Minitest.after_run { FileUtils.remove_entry(APP_ROOT) }
ENV["RAILS_ENV"] = "test"
ENV["DATABASE_URL"] = "sqlite3::memory:"
ENV["CLOUDFLARE_ACCOUNT_ID"] = "environment-account"
ENV["CLOUDFLARE_API_TOKEN"] = "environment-token"
ENV["CLOUDFLARE_INGRESS_SECRET"] = "integration-secret"
FileUtils.mkdir_p("#{APP_ROOT}/config/initializers")
FileUtils.cp(File.join(GEM_ROOT, "lib/generators/cloudflare/email/templates/initializer.rb"),
             "#{APP_ROOT}/config/initializers/cloudflare_email.rb")

class IntegrationApp < Rails::Application
  config.root = APP_ROOT
  config.eager_load = true
  config.secret_key_base = "a" * 64
  config.hosts.clear
  config.action_dispatch.show_exceptions = :none
  config.logger = Logger.new(File::NULL)
  if INBOUND
    config.active_job.queue_adapter = :test
    config.action_mailbox.ingress = :cloudflare
    config.active_storage.service = :test
    config.active_storage.service_configurations = {
      test: { service: "Disk", root: "#{APP_ROOT}/storage" },
    }
  end
end
IntegrationApp.initialize!

if INBOUND
  ActiveRecord::Migration.verbose = false
  %w[activestorage actionmailbox].each do |gem_name|
    Dir["#{Gem.loaded_specs.fetch(gem_name).full_gem_path}/db/migrate/*.rb"].each { |file| require file }
  end
  CreateActiveStorageTables.new.migrate(:up)
  CreateActionMailboxTables.new.migrate(:up)
end

class RailsAppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    Rails.application
  end

  def test_generated_initializer_uses_environment_credentials
    assert_equal :cloudflare, ActionMailer::Base.delivery_method
    assert_equal "environment-account", ActionMailer::Base.cloudflare_settings[:account_id]
    assert_equal "environment-token", ActionMailer::Base.cloudflare_settings[:api_token]
  end

  def test_dev_tunnel_rejects_test_and_production_before_external_work
    original_env = Rails.env
    %w[test production].each do |environment|
      Rails.env = environment
      error = assert_raises(RuntimeError) { Cloudflare::Email::DevTunnel.call }
      assert_match "only runs in development", error.message
    end
  ensure
    Rails.env = original_env
  end

  def test_dev_tunnel_requires_development_ingress
    original_env = Rails.env
    Rails.env = "development"
    if INBOUND
      original_ingress = Rails.application.config.action_mailbox.ingress
      Rails.application.config.action_mailbox.ingress = nil
    end
    error = assert_raises(RuntimeError) { Cloudflare::Email::DevTunnel.call }
    assert_match "config.action_mailbox.ingress = :cloudflare", error.message
  ensure
    Rails.env = original_env
    Rails.application.config.action_mailbox.ingress = original_ingress if INBOUND
  end

  if INBOUND
    def signed_post(body, timestamp: Time.now.to_i.to_s, signature: nil)
      signature ||= Cloudflare::Email::Verification.sign(secret: ENV.fetch("CLOUDFLARE_INGRESS_SECRET"), body: body, timestamp: timestamp)
      post "/rails/action_mailbox/cloudflare/inbound_emails", body,
        "CONTENT_TYPE" => "message/rfc822",
        "HTTP_X_CF_EMAIL_TIMESTAMP" => timestamp,
        "HTTP_X_CF_EMAIL_SIGNATURE" => signature
    end

    def test_real_ingress_persists_raw_message_and_acknowledges_duplicate
      body = "From: sender@example.com\r\nTo: receiver@example.com\r\nMessage-ID: <integration@example.com>\r\nSubject: Test\r\n\r\nHello\r\n"
      before = ActionMailbox::InboundEmail.count
      signed_post(body)
      assert_equal 200, last_response.status, last_response.body
      assert_equal before + 1, ActionMailbox::InboundEmail.count
      assert_equal body, ActionMailbox::InboundEmail.last.raw_email.download
      signed_post(body)
      assert_equal 200, last_response.status, last_response.body
      assert_equal before + 1, ActionMailbox::InboundEmail.count
    end

    def test_invalid_and_stale_signatures_do_not_persist_mail
      before = ActionMailbox::InboundEmail.count
      signed_post("invalid", signature: "0" * 64)
      assert_equal 401, last_response.status
      signed_post("stale", timestamp: (Time.now.to_i - 600).to_s)
      assert_equal 408, last_response.status
      assert_equal before, ActionMailbox::InboundEmail.count
    end

    def test_ingress_respects_action_mailbox_configuration
      ActionMailbox.ingress = :other
      signed_post("disabled")
      assert_equal 404, last_response.status
    ensure
      ActionMailbox.ingress = :cloudflare
    end
  else
    def test_send_only_boot_does_not_require_action_mailbox
      refute defined?(ActionMailbox)
      refute Rails.application.routes.routes.any? { |route| route.defaults[:controller] == "cloudflare/email/ingress" }
    end
  end

  def test_generator_does_not_register_deploy_helper_as_a_task
    refute Cloudflare::Email::Generators::InstallGenerator.all_tasks.key?("wrangler_deploy")
  end

  def test_tunnel_sets_localhost_header_for_rails_host_authorization
    tunnel = Cloudflare::Email::DevTunnel.new(port: 3456, io: StringIO.new)
    arguments = nil
    tunnel.define_singleton_method(:spawn) { |*args, **_options| arguments = args; nil }
    tunnel.send(:start_tunnel)
    assert_equal ["cloudflared", "tunnel", "--url", "http://127.0.0.1:3456", "--http-host-header", "localhost"], arguments
  ensure
    tunnel&.send(:cleanup)
  end

  def test_deploy_rake_task_forwards_custom_script_path
    require "rake"
    require "cloudflare/email/deploy_worker_task"
    Rails.application.load_tasks unless Rake::Task.task_defined?("cloudflare:email:deploy_worker")
    previous = ENV["SCRIPT"]
    ENV["SCRIPT"] = "custom-worker/src/index.js"
    captured = nil
    Cloudflare::Email::DeployWorkerTask.stub(:call, ->(**options) { captured = options; 0 }) do
      task = Rake::Task["cloudflare:email:deploy_worker"]
      task.reenable
      result = assert_raises(SystemExit) { task.invoke }
      assert_equal 0, result.status
    end
    assert_equal "custom-worker/src/index.js", captured[:script_path]
  ensure
    ENV["SCRIPT"] = previous
  end

  def test_generator_excludes_local_worker_secrets_and_build_artifacts
    Dir.mktmpdir do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p(source)
      %w[index.js .dev.vars .dev.vars.development .env .env.production].each do |name|
        File.write(File.join(source, name), "fixture")
      end
      %w[node_modules .wrangler].each do |name|
        FileUtils.mkdir_p(File.join(source, name))
        File.write(File.join(source, name, "artifact"), "fixture")
      end
      generator = Cloudflare::Email::Generators::InstallGenerator.new([], {}, destination_root: root)
      generator.define_singleton_method(:directory) { |_source, *args| super(source, *args) }
      capture_io { generator.copy_worker_template }
      assert_equal ["index.js"], Dir.children(File.join(root, "cloudflare-worker"))
    end
  end

  def test_generator_installs_without_network_and_sets_environment_defaults
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/config/environments")
      FileUtils.mkdir_p("#{root}/app/mailboxes")
      %w[development test production].each do |environment|
        File.write("#{root}/config/environments/#{environment}.rb", "Rails.application.configure do\nend\n")
      end
      File.write("#{root}/app/mailboxes/application_mailbox.rb", "class ApplicationMailbox < ActionMailbox::Base\nend\n")
      generator = Cloudflare::Email::Generators::InstallGenerator.new([], {
        inbound: !!INBOUND, deploy_worker: false, scaffold_mailbox: false, worker_dir: "custom-worker",
      }, destination_root: root)
      output, = capture_io { Dir.chdir(root) { generator.invoke_all } }
      assert_includes output, "FROM=hello@your-verified-domain.com TO=you@example.com"
      assert File.exist?("#{root}/config/initializers/cloudflare_email.rb")
      assert_equal !!INBOUND, File.exist?("#{root}/custom-worker/src/index.js")
      if INBOUND
        assert_includes output, "SCRIPT=custom-worker/src/index.js"
        assert File.exist?("#{root}/custom-worker/package-lock.json")
        assert File.exist?("#{root}/custom-worker/scripts/wrangler.mjs")
        refute File.exist?("#{root}/custom-worker/node_modules")
      end
      %w[development production].each do |environment|
        assert_equal !!INBOUND, File.read("#{root}/config/environments/#{environment}.rb").include?("config.action_mailbox.ingress = :cloudflare")
      end
      refute_includes File.read("#{root}/config/environments/test.rb"), "config.action_mailbox.ingress"
      if INBOUND
        all_envs = Cloudflare::Email::Generators::InstallGenerator.new([], {
          inbound: true, all_envs: true, deploy_worker: false, scaffold_mailbox: false,
        }, destination_root: root)
        capture_io { Dir.chdir(root) { all_envs.configure_action_mailbox_ingress } }
        %w[development test production].each do |environment|
          assert_equal 1, File.read("#{root}/config/environments/#{environment}.rb").scan("config.action_mailbox.ingress = :cloudflare").size
        end
      end
    end
  end
end
