require "test_helper"

class DeliveryEventTest < Minitest::Test
  def event_data(status = "delivered")
    {
      "type" => "cf.email.sending.message.#{status}",
      "source" => { "type" => "email.sending", "domain" => "send.example.com" },
      "payload" => {
        "eventId" => "event-123", "messageId" => "message-456",
        "sender" => "hello@send.example.com", "recipient" => "user@example.net",
        "terminal" => status != "deferred", "delivery" => { "status" => status },
      },
      "metadata" => {
        "accountId" => ACCOUNT_ID, "eventSchemaVersion" => 1,
        "eventTimestamp" => "2026-06-01T02:48:57.132Z",
      },
    }
  end

  def test_six_documented_statuses_and_terminality
    %w[delivered deferred bounced failed rejected complained].each do |status|
      event = Cloudflare::Email::DeliveryEvent.new(event_data(status))
      assert_equal status, event.status
      assert event.known?
      assert_equal status != "deferred", event.terminal?
    end
  end

  def test_unknown_future_event_preserves_payload
    raw = event_data("quarantined")
    raw["payload"]["futureDetail"] = { "reason" => "new provider status" }
    event = Cloudflare::Email::DeliveryEvent.new(raw)
    refute event.known?
    assert_equal "quarantined", event.status
    assert_equal raw, event.raw
    assert_equal raw["payload"]["futureDetail"], event.payload["futureDetail"]
  end

  def test_exposes_correlation_and_delivery_details
    raw = event_data
    %w[bounce complaint rejection failure].each { |field| raw["payload"][field] = { "reason" => field } }
    event = Cloudflare::Email::DeliveryEvent.new(raw)
    assert_equal "event-123", event.event_id
    assert_equal "message-456", event.message_id
    assert_equal "hello@send.example.com", event.sender
    assert_equal "user@example.net", event.recipient
    assert_equal "send.example.com", event.domain
    assert_equal ACCOUNT_ID, event.account_id
    assert_equal "2026-06-01T02:48:57.132Z", event.occurred_at
    assert_equal({ "status" => "delivered" }, event.delivery)
    %w[bounce complaint rejection failure].each do |field|
      assert_equal({ "reason" => field }, event.public_send(field))
    end
  end

  def test_missing_optional_details_default_to_empty_hashes
    raw = event_data
    raw["payload"].delete("delivery")
    event = Cloudflare::Email::DeliveryEvent.new(raw)
    %w[delivery bounce complaint rejection failure].each { |field| assert_equal({}, event.public_send(field)) }
  end

  def test_rejects_invalid_envelopes_and_unsupported_schema
    invalid = [nil, [], "event", {}]
    ["payload", "source", "metadata"].each do |key|
      invalid << event_data.merge(key => nil)
    end
    invalid << event_data.merge("type" => "cf.email.routing.message.delivered")
    invalid << event_data.merge("type" => "cf.email.sending.message.")
    raw = event_data
    raw["source"]["type"] = "email.routing"
    invalid << raw
    [nil, 2, "1"].each do |version|
      raw = event_data
      raw["metadata"]["eventSchemaVersion"] = version
      invalid << raw
    end
    %w[eventId messageId].each do |key|
      [nil, "", []].each do |value|
        raw = event_data
        raw["payload"][key] = value
        invalid << raw
      end
    end
    invalid.each do |raw|
      assert_raises(Cloudflare::Email::ValidationError, "accepted #{raw.inspect}") do
        Cloudflare::Email::DeliveryEvent.new(raw)
      end
    end
  end

  def test_rejects_malformed_projection_fields
    invalid = {
      ["payload", "recipient"] => [nil, "", "  ", [], "user\n@example.net"],
      ["payload", "terminal"] => [nil, "false", "true", 0, 1],
      ["metadata", "eventTimestamp"] => [nil, "", "tomorrow", 123, "2026-06-01T02:48:57Z\n"],
      ["payload", "eventId"] => ["  ", "event\0id"],
      ["payload", "messageId"] => ["  ", "message\rid"],
      ["metadata", "accountId"] => ["  ", "account\nid"],
      ["source", "domain"] => ["  ", "domain\tid"],
    }
    %w[delivery bounce complaint rejection failure].each do |field|
      invalid[["payload", field]] = [nil, false, "detail", []]
    end
    invalid.each do |(section, key), values|
      values.each do |value|
        raw = event_data
        raw[section][key] = value
        assert_raises(Cloudflare::Email::ValidationError, "accepted malformed #{section}.#{key}") do
          Cloudflare::Email::DeliveryEvent.new(raw)
        end
      end
    end
  end
end
