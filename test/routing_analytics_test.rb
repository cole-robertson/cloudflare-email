require "test_helper"
require "cloudflare/email/routing_analytics"

class RoutingAnalyticsTest < Minitest::Test
  Routing = Cloudflare::Email::RoutingAnalytics
  ZONE = "a" * 32

  def setup
    @client = Routing::Client.new(account_id: ACCOUNT_ID, zone_id: ZONE, api_token: API_TOKEN)
    @start, @finish = Time.now.utc - 120, Time.now.utc - 5
  end

  def verify(account: ACCOUNT_ID)
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE}")
      .with(headers: {"Authorization" => "Bearer #{API_TOKEN}"})
      .to_return(body: JSON.generate(result: {id: ZONE, account: {id: account}}))
    @client.verify_account!
  end

  def row(**overrides)
    {"messageId" => "<provider-1>", "sessionId" => "session-1", "datetime" => (@start + 10).iso8601,
      "eventType" => "newEmail", "status" => "delivered", "isNDR" => 0, "isLastEvent" => 1,
      "sampleInterval" => 1, "from" => "sender@example.com", "to" => "unrelated-mime-to@example.com"}.merge(overrides.transform_keys(&:to_s))
  end

  def response(rows = [row], zone: ZONE)
    stub_request(:post, "https://api.cloudflare.com/client/v4/graphql")
      .to_return(body: JSON.generate(data: {viewer: {zones: [{zoneTag: zone, emailRoutingAdaptive: rows}]}}))
  end

  def evidence
    @client.delivery_evidence(message_id: "provider-1", since: @start, until_time: @finish)
  end

  def test_authenticated_zone_binding_and_positive_evidence
    assert_raises(Routing::Error) { evidence }
    verify
    response
    result = evidence.fetch(0)
    assert_equal ACCOUNT_ID, result.account_id
    assert_equal ZONE, result.zone_id
    assert_equal "provider-1", result.message_id
    assert result.payload.frozen?
    assert result.event.frozen?
    refute_includes @client.inspect, API_TOKEN
  end

  def test_wrong_account_and_failed_reverification_revoke_access
    verify
    assert_raises(Routing::Error) { verify(account: "wrong") }
    assert_raises(Routing::Error) { evidence }
  end

  def test_wrong_zone_truncation_and_malformed_rows_are_visible
    verify
    [[[], "b" * 32], [[row] * 100, ZONE], [[nil], ZONE], [nil, ZONE]].each do |rows, zone|
      response(rows, zone: zone)
      assert_raises(Routing::Error) { evidence }
    end
  end

  def test_missing_sampled_nonterminal_forwarding_and_ndr_are_unresolved
    verify
    response([])
    assert_empty evidence
    response([row(sampleInterval: 2), row(isNDR: 1), row(isLastEvent: 0), row(status: "failed"), row(eventType: "forward")])
    assert_empty evidence
  end

  def test_qualifying_rows_must_match_identity_session_and_window
    verify
    [row(messageId: "wrong"), row(sessionId: ""), row(datetime: (@start - 10).iso8601),
      row(datetime: (@finish + 10).iso8601), row(datetime: "invalid"), row(from: nil)].each do |item|
      response([item])
      assert_raises(Routing::Error) { evidence }
    end
  end

  def test_errors_redact_provider_response_and_exception_causes
    verify
    ["not JSON #{API_TOKEN}", JSON.generate(errors: [{message: API_TOKEN}]), JSON.generate(data: {viewer: []})].each do |body|
      stub_request(:post, "https://api.cloudflare.com/client/v4/graphql").to_return(body: body)
      error = assert_raises(Routing::Error) { evidence }
      refute_includes error.message, API_TOKEN
      assert_nil error.cause
    end
    stub_request(:post, "https://api.cloudflare.com/client/v4/graphql").to_raise(IOError.new(API_TOKEN))
    error = assert_raises(Routing::Error) { evidence }
    refute_includes error.message, API_TOKEN
    assert_nil error.cause
  end

  def test_oversized_response_is_bounded
    verify
    stub_request(:post, "https://api.cloudflare.com/client/v4/graphql").to_return(body: "x" * (Routing::Client::MAX_RESPONSE_BYTES + 1))
    assert_raises(Routing::Error) { evidence }
  end

  def test_query_window_does_not_change_identity_or_stable_payload
    verify
    response
    first = evidence.first
    @start -= 10
    second = evidence.first
    assert_equal first.identity, second.identity
    assert first.same_event?(second)
    refute_equal first.payload, second.payload
  end

  def test_contradictory_final_events_are_rejected_before_returning_evidence
    verify
    [[row, row(status: "failed")], [row, row(from: "other@example.com")],
      [row, row(datetime: (@start + 11).iso8601)]].each do |rows|
      response(rows)
      assert_raises(Routing::Error) { evidence }
    end
  end
end
