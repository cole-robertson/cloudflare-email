$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "webmock/minitest"

require "cloudflare-email"

WebMock.disable_net_connect!(allow_localhost: true)

module TestHelpers
  ACCOUNT_ID = "test-account-123".freeze
  API_TOKEN  = "test-token-abc".freeze

  def send_endpoint
    "https://api.cloudflare.com/client/v4/accounts/#{ACCOUNT_ID}/email/sending/send"
  end

  def send_raw_endpoint
    "https://api.cloudflare.com/client/v4/accounts/#{ACCOUNT_ID}/email/sending/send_raw"
  end

  def make_client(**overrides)
    Cloudflare::Email::Client.new(
      account_id: ACCOUNT_ID,
      api_token:  API_TOKEN,
      retries:    overrides.fetch(:retries, 0),
      initial_backoff: 0.0,
      **overrides.except(:retries),
    )
  end

  # Matches the real Cloudflare API response shape: delivered/queued/permanent_bounces
  # are arrays of email strings, NOT hashes with message_id.
  def cloudflare_success_body(delivered: ["user@example.com"])
    {
      "success"  => true,
      "errors"   => [],
      "messages" => [],
      "result"   => {
        "delivered"         => delivered,
        "queued"            => [],
        "permanent_bounces" => [],
      },
    }
  end

  def cloudflare_error_body(message)
    { "success" => false, "errors" => [{ "code" => 1000, "message" => message }], "result" => nil }
  end
end

Minitest::Test.include(TestHelpers)
