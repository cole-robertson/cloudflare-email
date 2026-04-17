require "test_helper"
require "active_support"
require "active_support/notifications"

class ClientResilienceTest < Minitest::Test
  def test_instrumentation_fires_cloudflare_email_send_event
    stub_request(:post, send_endpoint)
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    events = []
    subscriber = ActiveSupport::Notifications.subscribe("cloudflare_email.send") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end

    make_client.send(from: "a@b.com", to: "c@d.com", subject: "x", text: "y")

    assert_equal 1, events.size
    payload = events.first.payload
    assert_equal ACCOUNT_ID, payload[:account_id]
    assert_equal 200, payload[:status]
    assert_nil payload[:message_id]  # Cloudflare API does not return message_id
    assert payload[:path].include?("/email/sending/send")
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def test_instrumentation_fires_cloudflare_email_send_raw_event
    stub_request(:post, send_raw_endpoint)
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    events = []
    subscriber = ActiveSupport::Notifications.subscribe("cloudflare_email.send_raw") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end

    make_client.send_raw(from: "a@b.com", recipients: "c@d.com", mime_message: "From: a\r\n\r\nx")

    assert_equal 1, events.size
    assert payload_path(events.first).include?("send_raw")
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # Client subclass that records sleeps instead of blocking.
  class SleepTrackingClient < Cloudflare::Email::Client
    attr_reader :sleep_calls

    def initialize(**args)
      super
      @sleep_calls = []
    end

    private def sleep(seconds); @sleep_calls << seconds; end
  end

  def test_retry_after_header_on_429_is_honored
    stub_request(:post, send_endpoint)
      .to_return(
        { status: 429, headers: { "Retry-After" => "2" }, body: JSON.generate(cloudflare_error_body("rate")) },
        { status: 200, body: JSON.generate(cloudflare_success_body) },
      )

    client = SleepTrackingClient.new(
      account_id: ACCOUNT_ID, api_token: API_TOKEN, retries: 1, initial_backoff: 0.0,
    )

    response = client.send(from: "a@b.com", to: "c@d.com", subject: "x", text: "y")

    assert response.success?
    assert_equal [2.0], client.sleep_calls
  end

  def test_retry_after_caps_at_max_retry_after
    stub_request(:post, send_endpoint)
      .to_return(
        { status: 429, headers: { "Retry-After" => "9999" }, body: JSON.generate(cloudflare_error_body("rate")) },
        { status: 200, body: JSON.generate(cloudflare_success_body) },
      )

    client = SleepTrackingClient.new(
      account_id: ACCOUNT_ID, api_token: API_TOKEN,
      retries: 1, initial_backoff: 0.0, max_retry_after: 5,
    )

    client.send(from: "a@b.com", to: "c@d.com", subject: "x", text: "y")
    assert_equal [5.0], client.sleep_calls
  end

  def test_429_without_retry_after_falls_back_to_backoff
    stub_request(:post, send_endpoint)
      .to_return(
        { status: 429, body: JSON.generate(cloudflare_error_body("rate")) },
        { status: 200, body: JSON.generate(cloudflare_success_body) },
      )

    client = SleepTrackingClient.new(
      account_id: ACCOUNT_ID, api_token: API_TOKEN, retries: 1, initial_backoff: 0.25,
    )

    client.send(from: "a@b.com", to: "c@d.com", subject: "x", text: "y")
    assert_equal [0.25], client.sleep_calls
  end

  def test_concurrent_sends_are_thread_safe
    stub_request(:post, send_endpoint)
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    client = make_client
    results = Array.new(20)

    threads = 20.times.map do |i|
      Thread.new do
        results[i] = client.send(
          from: "a@b.com", to: "c#{i}@d.com", subject: "msg #{i}", text: "hello",
        )
      end
    end
    threads.each(&:join)

    assert(results.all? { |r| r.is_a?(Cloudflare::Email::Response) && r.success? })
    assert_requested :post, send_endpoint, times: 20
  end

  def test_large_email_roundtrips_through_send_raw
    twenty_mb_body = "x" * (20 * 1024 * 1024)
    mime = "From: a@b.com\r\nTo: c@d.com\r\nSubject: big\r\n" \
           "Content-Type: text/plain\r\n\r\n#{twenty_mb_body}"

    stub_request(:post, send_raw_endpoint)
      .with { |req|
        body = JSON.parse(req.body)
        assert_equal mime.bytesize, body["mime_message"].bytesize
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    response = make_client.send_raw(
      from: "a@b.com", recipients: "c@d.com", mime_message: mime,
    )
    assert response.success?
  end

  private

  def payload_path(event)
    event.payload[:path].to_s
  end
end
