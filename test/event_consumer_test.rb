require "test_helper"
require "base64"

class EventConsumerTest < Minitest::Test
  def setup
    @consumer = Cloudflare::Email::EventConsumer.new(
      queue_id: "queue-123", account_id: ACCOUNT_ID, api_token: API_TOKEN,
      domains: ["SEND.EXAMPLE.COM"], initial_backoff: 0,
    )
  end

  def endpoint(action)
    "https://api.cloudflare.com/client/v4/accounts/#{ACCOUNT_ID}/queues/queue-123/messages/#{action}"
  end

  def event_data
    {
      "type" => "cf.email.sending.message.delivered",
      "source" => { "type" => "email.sending", "domain" => "send.example.com" },
      "payload" => { "eventId" => "event-123", "messageId" => "message-456", "terminal" => true },
      "metadata" => { "accountId" => ACCOUNT_ID, "eventSchemaVersion" => 1 },
    }
  end

  def queue_message(raw = event_data, content_type: "json", lease: "lease-123")
    json = JSON.generate(raw)
    {
      "lease_id" => lease,
      "body" => content_type == "text" ? json : Base64.strict_encode64(json),
      "metadata" => { "CF-Content-Type" => content_type },
    }
  end

  def api_body(result)
    JSON.generate("success" => true, "result" => result)
  end

  def stub_pull(messages)
    stub_request(:post, endpoint("pull")).with(
      headers: { "Authorization" => "Bearer #{API_TOKEN}" },
      body: { batch_size: 5, visibility_timeout_ms: 300_000 }.to_json,
    ).to_return(body: api_body("messages" => messages))
  end

  def stub_ack(lease = "lease-123", result: { "ackCount" => 1, "retryCount" => 0, "warnings" => {} })
    stub_request(:post, endpoint("ack")).with(
      body: { acks: [{ lease_id: lease }], retries: [] }.to_json,
    ).to_return(body: api_body(result))
  end

  def test_decodes_all_three_documented_content_types_and_acknowledges_after_handler
    %w[json bytes text].each do |content_type|
      WebMock.reset!
      stub_pull([queue_message(content_type: content_type)])
      ack = stub_ack
      count = @consumer.poll do |event|
        assert_equal "message-456", event.message_id
        assert_equal "delivered", event.status
        assert_not_requested ack
      end
      assert_equal 1, count
      assert_requested ack, times: 1
    end
  end

  def test_empty_poll_does_not_call_handler_or_ack
    stub_pull([])
    assert_equal 0, @consumer.poll { flunk "empty queue yielded an event" }
    assert_not_requested :post, endpoint("ack")
  end

  def test_decodes_real_email_sending_subscription_plain_json_transport
    # Structure captured from a live HTTP pull; identifiers/content replaced,
    # and queue message id / live lease deliberately excluded from the fixture.
    message = JSON.parse(File.read(File.join(__dir__, "fixtures/email_sending_queue_message.json")))
    refute message.key?("lease_id")
    refute message.key?("id")
    message["lease_id"] = "lease-123"
    stub_pull([message])
    ack = stub_ack
    count = @consumer.poll do |event|
      assert_equal "message-456", event.message_id
      assert_equal "delivered", event.status
      assert_equal "recipient@example.net", event.recipient
      assert event.terminal?
      assert_not_requested ack
    end
    assert_equal 1, count
    assert_requested ack, times: 1
  end

  def test_requires_handler_before_pulling
    assert_raises(ArgumentError) { @consumer.poll }
    assert_not_requested :post, endpoint("pull")
  end

  def test_failed_handler_is_not_acknowledged
    stub_pull([queue_message])
    error = assert_raises(RuntimeError) { @consumer.poll { raise "database unavailable" } }
    assert_equal "database unavailable", error.message
    assert_not_requested :post, endpoint("ack")
  end

  def test_account_and_domain_mismatches_are_not_acknowledged
    [["metadata", "accountId", "other-account"], ["source", "domain", "other.example.com"]].each do |section, key, value|
      WebMock.reset!
      raw = event_data
      raw[section][key] = value
      stub_pull([queue_message(raw)])
      assert_raises(Cloudflare::Email::ValidationError) { @consumer.poll { flunk "mismatched event yielded" } }
      assert_not_requested :post, endpoint("ack")
    end
  end

  def test_malformed_messages_are_not_acknowledged
    invalid = [
      queue_message.merge("body" => "not base64!"),
      queue_message.merge("body" => Base64.strict_encode64("not JSON")),
      queue_message.merge("metadata" => nil),
      queue_message.merge("metadata" => { "CF-Content-Type" => "v8" }),
      queue_message.merge("lease_id" => ""),
      queue_message({ "unrelated" => true }),
      queue_message.merge("body" => '{"unrelated":true}'),
      queue_message.merge("body" => '{"type":'),
      queue_message.merge("body" => "null"),
      queue_message.merge("body" => "[]"),
      queue_message.merge("body" => JSON.generate("not an event")),
      queue_message.merge("body" => nil),
      queue_message.merge("body" => event_data),
      queue_message.merge("body" => JSON.generate(event_data.merge("metadata" => { "accountId" => ACCOUNT_ID, "eventSchemaVersion" => 2 }))),
    ]
    invalid.each do |raw|
      WebMock.reset!
      stub_pull([raw])
      assert_raises(Cloudflare::Email::ValidationError) { @consumer.poll { flunk "malformed event yielded" } }
      assert_not_requested :post, endpoint("ack")
    end
  end

  def test_ack_http_failure_propagates_without_retrying_handler_or_ack
    stub_pull([queue_message])
    ack = stub_request(:post, endpoint("ack")).to_return(status: 503, body: cloudflare_error_body("unavailable").to_json)
    handled = 0
    assert_raises(Cloudflare::Email::Error) { @consumer.poll { handled += 1 } }
    assert_equal 1, handled
    assert_requested ack, times: 1
  end

  def test_successful_http_response_with_no_acknowledged_message_is_failure
    stub_pull([queue_message])
    stub_ack(result: { "ackCount" => 0, "warnings" => { "lease-123" => "lease expired" } })
    error = assert_raises(Cloudflare::Email::Error) { @consumer.poll { |_event| } }
    assert_equal "lease expired", error.response.dig("result", "warnings", "lease-123")
  end

  def test_missing_ack_count_is_not_reported_as_success
    stub_pull([queue_message])
    stub_ack(result: {})
    assert_raises(Cloudflare::Email::Error) { @consumer.poll { |_event| } }
  end

  def test_invalid_pull_result_does_not_yield_or_ack
    stub_request(:post, endpoint("pull")).to_return(body: api_body(nil))
    assert_raises(Cloudflare::Email::Error) { @consumer.poll { flunk "invalid pull yielded" } }
    assert_not_requested :post, endpoint("ack")
  end

  def test_successful_batch_acknowledges_each_lease
    stub_pull([queue_message(lease: "first"), queue_message(lease: "second")])
    first_ack = stub_ack("first")
    second_ack = stub_ack("second")
    assert_equal 2, @consumer.poll { |_event| }
    assert_requested first_ack, times: 1
    assert_requested second_ack, times: 1
  end

  def test_partial_batch_failure_preserves_prior_acknowledgements
    stub_pull([queue_message(lease: "first"), queue_message(lease: "second"), queue_message(lease: "third")])
    first_ack = stub_ack("first")
    handled = 0
    assert_raises(RuntimeError) do
      @consumer.poll do |_event|
        handled += 1
        raise "second event failed" if handled == 2
      end
    end
    assert_equal 2, handled
    assert_requested first_ack, times: 1
    assert_requested :post, endpoint("ack"), times: 1
  end

  def test_validates_pull_limits_before_requesting
    [0, 101, "5"].each do |size|
      assert_raises(ArgumentError) { @consumer.poll(batch_size: size) { |_event| } }
    end
    [999, 43_200_001, "300000"].each do |timeout|
      assert_raises(ArgumentError) { @consumer.poll(visibility_timeout_ms: timeout) { |_event| } }
    end
    assert_not_requested :post, endpoint("pull")
  end
end
