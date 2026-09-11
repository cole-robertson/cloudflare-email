require "test_helper"
require_relative "delivery_event_test"

class DeliveryPrimitivesTest < Minitest::Test
  def response(**result)
    Cloudflare::Email::Response.new({ "success" => true, "result" => result.transform_keys(&:to_s) })
  end

  def test_acceptance_requires_positive_evidence
    refute response.accepted?
    refute response(message_id: " ").accepted?
    assert response(message_id: "provider@example.com").accepted?
    assert response(queued: ["a@example.com"]).accepted?
    refute response(permanent_bounces: ["a@example.com"]).accepted?
    refute response(message_id: "id", suppressed_recipients: ["a@example.com"]).accepted?
    assert response(delivered: ["a@example.com"], permanent_bounces: ["b@example.com"]).accepted?
    refute Cloudflare::Email::Response.new({ "success" => false, "result" => { "message_id" => "id" } }).accepted?
  end

  def event(status = "delivered")
    Cloudflare::Email::DeliveryEvent.new(DeliveryEventTest.new("fixture").event_data(status))
  end

  def test_delivery_state_never_regresses_to_an_older_or_nonterminal_event
    time = Time.iso8601(event.occurred_at)
    assert event.supersedes?(occurred_at: nil, terminal: false)
    assert event.supersedes?(occurred_at: time - 1, terminal: false)
    refute event.supersedes?(occurred_at: time, terminal: true)
    refute event.supersedes?(occurred_at: time + 1, terminal: false)
    refute event("deferred").supersedes?(occurred_at: time - 1, terminal: true)
    assert event("complained").supersedes?(occurred_at: (time - 1).iso8601, terminal: true)
    refute event("future").supersedes?(occurred_at: nil, terminal: false)
    assert_raises(ArgumentError) { event.supersedes?(occurred_at: "invalid", terminal: false) }
  end

  def test_message_ids_preserve_case_and_only_remove_one_complete_bracket_pair
    normalizer = Cloudflare::Email::MessageId
    assert_equal "ABC@example.com", normalizer.normalize(" <ABC@example.com> \n")
    assert_equal "", normalizer.normalize(nil)
    assert_equal "<a> <b>", normalizer.normalize("<a> <b>")
  end
end
