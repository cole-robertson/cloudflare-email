require "test_helper"
require "cloudflare/email/credentials"

class CredentialsTest < Minitest::Test
  def setup
    @env_backup = ENV.select { |k, _| k.start_with?("CLOUDFLARE_") }
    @env_backup.keys.each { |k| ENV.delete(k) }
  end

  def teardown
    ENV.to_h.keys.each { |k| ENV.delete(k) if k.start_with?("CLOUDFLARE_") }
    @env_backup.each { |k, v| ENV[k] = v }
  end

  def test_fetch_reads_from_env_when_rails_not_loaded
    ENV["CLOUDFLARE_ACCOUNT_ID"] = "from-env-123"
    assert_equal "from-env-123", Cloudflare::Email::Credentials.account_id
  end

  def test_fetch_returns_empty_string_for_missing
    assert_equal "", Cloudflare::Email::Credentials.api_token
  end

  def test_management_token_falls_back_to_api_token
    ENV["CLOUDFLARE_API_TOKEN"] = "only-token"
    assert_equal "only-token", Cloudflare::Email::Credentials.management_token
    refute Cloudflare::Email::Credentials.split_tokens?
  end

  def test_management_token_prefers_dedicated_when_set
    ENV["CLOUDFLARE_API_TOKEN"]        = "runtime"
    ENV["CLOUDFLARE_MANAGEMENT_TOKEN"] = "admin"
    assert_equal "admin", Cloudflare::Email::Credentials.management_token
    assert_equal "runtime", Cloudflare::Email::Credentials.api_token
    assert Cloudflare::Email::Credentials.split_tokens?
  end

  def test_rails_credentials_take_precedence_over_env
    original = Cloudflare::Email::Credentials.method(:rails_credentials_dig)
    Cloudflare::Email::Credentials.define_singleton_method(:rails_credentials_dig) do |key|
      key == :api_token ? "from-creds" : ""
    end

    ENV["CLOUDFLARE_API_TOKEN"] = "from-env"
    assert_equal "from-creds", Cloudflare::Email::Credentials.api_token
  ensure
    Cloudflare::Email::Credentials.define_singleton_method(:rails_credentials_dig, original) if original
  end

  def test_handles_missing_rails_gracefully
    assert_equal "", Cloudflare::Email::Credentials.ingress_secret
  end
end
