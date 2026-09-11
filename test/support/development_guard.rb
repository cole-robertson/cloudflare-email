ENV["RAILS_ENV"] = "development"
require "tmpdir"
require "fileutils"
require "minitest/autorun"
require "rails"
require "action_controller/railtie"
gem_root = ENV.fetch("CLOUDFLARE_EMAIL_TEST_GEM_ROOT", File.expand_path("../..", __dir__))
$LOAD_PATH.unshift File.join(gem_root, "lib")
require "cloudflare-email"
require "rack/mock"

GUARD_ROOT = Dir.mktmpdir("cloudflare-email-guard")
Minitest.after_run { FileUtils.remove_entry(GUARD_ROOT) }
class GuardDevelopmentApp < Rails::Application
  config.root = GUARD_ROOT
  config.eager_load = false
  config.secret_key_base = "x" * 64
  config.hosts = ["localhost"]
  config.logger = Logger.new(File::NULL)
end
GuardDevelopmentApp.initialize!
Rails.application.routes.draw do
  get "/", to: ->(_env) { [200, { "content-type" => "text/plain" }, ["local development"]] }
  post Cloudflare::Email::DevIngressGuard::PATH, to: ->(_env) { [204, {}, []] }
end

class DevelopmentGuardTest < Minitest::Test
  def test_guard_is_installed_before_host_authorization_and_routing
    request = Rack::MockRequest.new(Rails.application)
    guard = Cloudflare::Email::DevIngressGuard
    hidden = request.get("/", "HTTP_HOST" => guard::HOST)
    assert_equal 404, hidden.status
    assert_equal "1", hidden[guard::RESPONSE_HEADER]
    assert_empty hidden.body
    assert_equal 200, request.get("/", "HTTP_HOST" => "localhost").status
    accepted = request.post(guard::PATH, "HTTP_HOST" => guard::HOST,
      "HTTP_X_FORWARDED_HOST" => "public.example.test")
    assert_equal 204, accepted.status
  end
end
