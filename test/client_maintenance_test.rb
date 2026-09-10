require "test_helper"
require "active_support"
require "active_support/notifications"

class ClientMaintenanceTest < Minitest::Test
  class TrackingClient < Cloudflare::Email::Client
    attr_reader :delays
    def initialize(**options)
      super
      @delays = []
    end
    private def sleep(delay)
      @delays << delay
    end
  end

  def send_message(client = make_client(retries: 3))
    client.send(from: "sender@example.com", to: "to@example.net", subject: "Hello", text: "Body")
  end

  def test_ambiguous_network_failures_never_retry_by_default
    [Net::ReadTimeout, Net::WriteTimeout, Errno::ECONNRESET, EOFError].each do |failure|
      WebMock.reset!
      request = stub_request(:post, send_endpoint).to_raise(failure)
      error = assert_raises(Cloudflare::Email::NetworkError) { send_message }
      assert_match(/outcome is unknown/, error.message)
      assert_requested request, times: 1
    end
  end

  def test_server_failure_never_retries_by_default
    request = stub_request(:post, send_endpoint).to_return(status: 503, body: JSON.generate(cloudflare_error_body("Unavailable")))
    assert_raises(Cloudflare::Email::ServerError) { send_message }
    assert_requested request, times: 1
  end

  def test_connection_failure_before_send_retries
    request = stub_request(:post, send_endpoint).to_raise(Net::OpenTimeout)
      .then.to_return(status: 200, body: JSON.generate(cloudflare_success_body))
    assert send_message.success?
    assert_requested request, times: 2
  end

  def test_ambiguous_retry_opt_in_can_recover
    request = stub_request(:post, send_endpoint).to_raise(Net::ReadTimeout)
      .then.to_return(status: 200, body: JSON.generate(cloudflare_success_body))
    assert send_message(make_client(retries: 1, retry_ambiguous: true)).success?
    assert_requested request, times: 2
  end

  def test_retry_after_http_date_is_honored_and_capped
    now = Time.utc(2026, 9, 10, 12)
    stub_request(:post, send_endpoint).to_return(
      { status: 429, headers: { "Retry-After" => (now + 120).httpdate }, body: JSON.generate(cloudflare_error_body("rate")) },
      { status: 200, body: JSON.generate(cloudflare_success_body) })
    client = TrackingClient.new(account_id: ACCOUNT_ID, api_token: API_TOKEN, retries: 1, max_retry_after: 10)
    Time.stub(:now, now) { assert send_message(client).success? }
    assert_equal [10], client.delays
  end

  def test_invalid_retry_after_uses_configured_backoff
    stub_request(:post, send_endpoint).to_return(
      { status: 429, headers: { "Retry-After" => "not a date" }, body: JSON.generate(cloudflare_error_body("rate")) },
      { status: 200, body: JSON.generate(cloudflare_success_body) })
    client = TrackingClient.new(account_id: ACCOUNT_ID, api_token: API_TOKEN, retries: 1, initial_backoff: 0.125)
    send_message(client)
    assert_equal [0.125], client.delays
  end

  def test_success_false_with_http_200_raises_without_retry
    request = stub_request(:post, send_endpoint).to_return(status: 200, body: JSON.generate(cloudflare_error_body("Rejected")))
    error = assert_raises(Cloudflare::Email::Error) { send_message }
    assert_match(/Rejected/, error.message)
    assert_requested request, times: 1
  end

  def test_invalid_success_envelopes_raise_without_resending
    ["", "<html>maintenance</html>", "null", "[]", "1", '{"success":true}'].each do |body|
      request = stub_request(:post, send_endpoint).to_return(status: 200, body: body)
      error = assert_raises(Cloudflare::Email::Error) { send_message }
      assert_match(/outcome is unknown/, error.message)
      assert_requested request, times: 1
      WebMock.reset!
    end
  end

  def test_cc_only_and_bcc_only_sends_omit_to
    [:cc, :bcc].each do |field|
      request = stub_request(:post, send_endpoint).with do |req|
        body = JSON.parse(req.body)
        !body.key?("to") && body[field.to_s] == ["recipient@example.net"]
      end.to_return(status: 200, body: JSON.generate(cloudflare_success_body))
      assert make_client.send(from: "sender@example.com", subject: "Hello", text: "Body", **{ field => "recipient@example.net" }).success?
      assert_requested request
    end
  end

  def test_empty_recipients_fail_before_request
    assert_raises(Cloudflare::Email::ValidationError) do
      make_client.send(from: "sender@example.com", to: [], cc: [], bcc: [], subject: "Hello", text: "Body")
    end
    WebMock.assert_not_requested(:post, send_endpoint)
  end

  def test_notification_includes_message_id_and_all_recipient_outcomes
    outcomes = { "message_id" => "cloudflare-id", "delivered" => ["delivered@example.net"],
      "queued" => ["queued@example.net"], "permanent_bounces" => ["bounce@example.net"],
      "suppressed_recipients" => ["suppressed@example.net"] }
    stub_request(:post, send_endpoint).to_return(status: 200, body: JSON.generate("success" => true, "result" => outcomes))
    payloads = []
    subscriber = ActiveSupport::Notifications.subscribe("cloudflare_email.send") { |*args| payloads << args.last }
    response = send_message
    outcomes.each { |key, value| assert_equal value, payloads.fetch(0)[key.to_sym] }
    assert_equal outcomes["suppressed_recipients"], response.suppressed_recipients
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
