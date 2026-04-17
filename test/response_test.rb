require "test_helper"

class ResponseTest < Minitest::Test
  def test_success_from_payload
    r = Cloudflare::Email::Response.new({ "success" => true, "result" => {} })
    assert r.success?
  end

  def test_message_id_from_top_level_result
    r = Cloudflare::Email::Response.new({ "result" => { "message_id" => "abc" } })
    assert_equal "abc", r.message_id
  end

  def test_message_id_nil_when_delivered_is_string_array
    # Real Cloudflare API: delivered is ["email@example.com"], not [{message_id: ...}]
    r = Cloudflare::Email::Response.new({
      "result" => { "delivered" => ["user@example.com"] },
    })
    assert_nil r.message_id
  end

  def test_message_id_extracted_if_api_ever_returns_hash_array
    # Forward-compat: if Cloudflare ever adds message_id to delivered objects
    r = Cloudflare::Email::Response.new({
      "result" => { "delivered" => [{ "message_id" => "from-delivered" }] },
    })
    assert_equal "from-delivered", r.message_id
  end

  def test_errors_array_default_empty
    r = Cloudflare::Email::Response.new({})
    assert_equal [], r.errors
    assert_equal [], r.delivered
    assert_equal [], r.queued
    assert_equal [], r.permanent_bounces
  end

  def test_status_falls_back_to_success
    r = Cloudflare::Email::Response.new({}, status: 201)
    assert r.success?
  end
end
