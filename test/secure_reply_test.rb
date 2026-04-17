require "test_helper"
require "active_support"
require "active_support/security_utils"
require "cloudflare/email/secure_reply"

class SecureReplyTest < Minitest::Test
  SECRET = "super-secret-key-for-reply-addresses-1234567890".freeze
  DOMAIN = "in.example.com".freeze
  NOW    = 1_780_000_000  # 2026-05-29, safely after EPOCH_OFFSET (2026-01-01)

  # Keep the default fixture payload small enough to fit in 64-char local part.
  def encode_fixture(payload = { "t" => "42" }, **opts)
    Cloudflare::Email::SecureReply.encode(
      payload: payload, domain: DOMAIN, secret: SECRET, now: NOW, **opts,
    )
  end

  def test_round_trip_recovers_payload
    addr = encode_fixture({ "t" => "42" })
    decoded = Cloudflare::Email::SecureReply.decode(addr, secret: SECRET, now: NOW)
    assert_equal({ "t" => "42" }, decoded)
  end

  def test_encode_format
    addr = encode_fixture({ "i" => 1 })
    # HMAC is truncated to 32 hex chars (128 bits) to fit within the RFC 5321
    # 64-char local-part limit enforced by Cloudflare's sending validator.
    assert_match(/\Areply\.[A-Za-z0-9_\-]+\.[0-9a-f]{32}@in\.example\.com\z/, addr)
  end

  def test_encode_raises_when_payload_too_large
    big = { "x" => "a" * 100 }
    assert_raises(Cloudflare::Email::SecureReply::PayloadTooLarge) do
      Cloudflare::Email::SecureReply.encode(
        payload: big, domain: "example.com", secret: SECRET,
      )
    end
  end

  def test_encode_fits_within_rfc_local_part
    addr = encode_fixture({ "id" => "abc" })
    local = addr.split("@").first
    assert_operator local.bytesize, :<=, 64
  end

  def test_custom_local_part
    addr = encode_fixture({ "t" => "42" }, local_part: "bounce")
    assert addr.start_with?("bounce.")
    decoded = Cloudflare::Email::SecureReply.decode(addr, secret: SECRET, now: NOW)
    assert_equal({ "t" => "42" }, decoded)
  end

  def test_decode_rejects_tampered_payload
    addr = encode_fixture
    # Swap out the base64 portion entirely
    tampered = addr.sub(/\.[A-Za-z0-9_\-]+\./, ".AAAA.")
    assert_raises(Cloudflare::Email::SecureReply::InvalidToken) do
      Cloudflare::Email::SecureReply.decode(tampered, secret: SECRET, now: NOW)
    end
  end

  def test_decode_rejects_wrong_secret
    addr = encode_fixture
    assert_raises(Cloudflare::Email::SecureReply::InvalidToken) do
      Cloudflare::Email::SecureReply.decode(addr, secret: "different-secret", now: NOW)
    end
  end

  def test_decode_rejects_expired_tokens
    addr = encode_fixture
    # 31 days later with default 30-day max_age
    assert_raises(Cloudflare::Email::SecureReply::InvalidToken, /expired/) do
      Cloudflare::Email::SecureReply.decode(addr, secret: SECRET, now: NOW + (31 * 24 * 60 * 60))
    end
  end

  def test_decode_accepts_just_before_expiry
    addr = encode_fixture({ "t" => "42" })
    # 29 days later — still within 30-day window
    decoded = Cloudflare::Email::SecureReply.decode(addr, secret: SECRET, now: NOW + (29 * 24 * 60 * 60))
    assert_equal "42", decoded["t"]
  end

  def test_decode_rejects_future_timestamp
    # Someone tries to replay from 10 minutes in the future
    addr = encode_fixture
    assert_raises(Cloudflare::Email::SecureReply::InvalidToken, /future/) do
      Cloudflare::Email::SecureReply.decode(addr, secret: SECRET, now: NOW - (10 * 60))
    end
  end

  def test_decode_custom_max_age
    addr = encode_fixture
    # 2 hour max; 3 hours later → expired
    assert_raises(Cloudflare::Email::SecureReply::InvalidToken) do
      Cloudflare::Email::SecureReply.decode(
        addr, secret: SECRET, max_age: 2 * 60 * 60, now: NOW + (3 * 60 * 60),
      )
    end
    # Within 2 hour window → ok
    decoded = Cloudflare::Email::SecureReply.decode(
      addr, secret: SECRET, max_age: 2 * 60 * 60, now: NOW + (60 * 60),
    )
    assert_equal "42", decoded["t"]
  end

  def test_decode_rejects_malformed
    ["", "foo@bar.com", "reply@in.example.com", "reply.nonsense@in.example.com",
     "reply..@in.example.com", "no_at_sign"].each do |bad|
      assert_raises(Cloudflare::Email::SecureReply::InvalidToken) do
        Cloudflare::Email::SecureReply.decode(bad, secret: SECRET, now: NOW)
      end
    end
  end

  def test_match_heuristic
    assert Cloudflare::Email::SecureReply.match?(encode_fixture)
    refute Cloudflare::Email::SecureReply.match?("plain@example.com")
    refute Cloudflare::Email::SecureReply.match?("other.abc.def@example.com")
    assert Cloudflare::Email::SecureReply.match?(
      encode_fixture({}, local_part: "bounce"),
      local_part: "bounce",
    )
  end

  def test_encode_requires_secret
    assert_raises(ArgumentError) do
      Cloudflare::Email::SecureReply.encode(payload: {}, domain: DOMAIN, secret: "")
    end
  end

  def test_encode_requires_domain
    assert_raises(ArgumentError) do
      Cloudflare::Email::SecureReply.encode(payload: {}, domain: "", secret: SECRET)
    end
  end

  def test_different_payloads_produce_different_signatures
    a = encode_fixture({ "x" => 1 })
    b = encode_fixture({ "x" => 2 })
    refute_equal a, b
  end

  def test_same_payload_same_time_is_deterministic
    a = encode_fixture
    b = encode_fixture
    assert_equal a, b
  end
end
