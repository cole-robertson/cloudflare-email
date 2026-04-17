require "test_helper"

class ResponseEdgeCasesTest < Minitest::Test
  def test_success_false_in_payload
    r = Cloudflare::Email::Response.new({ "success" => false })
    refute r.success?
  end

  def test_status_2xx_implies_success_if_no_success_key
    r = Cloudflare::Email::Response.new({}, status: 202)
    assert r.success?
  end

  def test_status_non_2xx_does_not_imply_success
    r = Cloudflare::Email::Response.new({}, status: 500)
    refute r.success?
  end

  def test_message_id_nil_when_no_fields
    r = Cloudflare::Email::Response.new({ "result" => {} })
    assert_nil r.message_id
  end

  def test_message_id_nil_when_queued_is_string_array
    r = Cloudflare::Email::Response.new({
      "result" => { "queued" => ["user@example.com"] }
    })
    assert_nil r.message_id
  end

  def test_message_id_from_queued_hash_fallback
    # Forward-compat: if Cloudflare ever returns hashes in queued
    r = Cloudflare::Email::Response.new({
      "result" => { "queued" => [{ "message_id" => "q-1" }] }
    })
    assert_equal "q-1", r.message_id
  end

  def test_messages_and_errors_arrays
    r = Cloudflare::Email::Response.new({
      "messages" => [{ "message" => "ok" }],
      "errors"   => [{ "message" => "warn" }],
    })
    assert_equal 1, r.messages.size
    assert_equal 1, r.errors.size
  end

  def test_to_h_returns_raw_payload
    payload = { "success" => true, "result" => { "message_id" => "m1" } }
    r = Cloudflare::Email::Response.new(payload)
    assert_equal payload, r.to_h
  end

  def test_handles_non_hash_result_gracefully
    r = Cloudflare::Email::Response.new({ "result" => nil })
    assert_equal({}, r.result)
    assert_nil r.message_id
  end

  def test_permanent_bounces_array
    r = Cloudflare::Email::Response.new({
      "result" => {
        "permanent_bounces" => [
          { "to" => "a@dead.com", "message" => "No such user" }
        ]
      }
    })
    assert_equal 1, r.permanent_bounces.size
    assert_equal "a@dead.com", r.permanent_bounces.first["to"]
  end
end
