require "test_helper"
require "active_support"
require "active_support/security_utils"
require "cloudflare/email/secure_message_id"

class SecureMessageIdTest < Minitest::Test
  SECRET = "secure-message-id-test-secret-aaaaaaaaaaaa".freeze
  DOMAIN = "mail.example.com".freeze
  NOW    = 1_780_000_000 # 2026-05-29

  def encode_fixture(payload = { "thread_id" => 42, "user_id" => 7, "kind" => "ping" }, **opts)
    Cloudflare::Email::SecureMessageId.encode(
      payload: payload, domain: DOMAIN, secret: SECRET, now: NOW, **opts,
    )
  end

  def test_round_trip_recovers_payload
    id = encode_fixture
    payload = Cloudflare::Email::SecureMessageId.decode(id, secret: SECRET, now: NOW)
    assert_equal({ "thread_id" => 42, "user_id" => 7, "kind" => "ping" }, payload)
  end

  def test_no_size_constraint
    # 200-char payload in a Message-ID — no local-part size ceiling here.
    big = { "state" => "x" * 200 }
    id  = encode_fixture(big)
    local = id.split("@").first
    assert_operator local.bytesize, :>, 200

    decoded = Cloudflare::Email::SecureMessageId.decode(id, secret: SECRET, now: NOW)
    assert_equal big, decoded
  end

  def test_format
    id = encode_fixture
    assert_match(/\Amsg\.[A-Za-z0-9_\-]+\.[0-9a-f]{64}@mail\.example\.com\z/, id)
  end

  def test_custom_prefix
    id = encode_fixture(prefix: "thread")
    assert id.start_with?("thread.")
  end

  def test_decode_accepts_angle_brackets
    id = encode_fixture
    wrapped = "<#{id}>"
    decoded = Cloudflare::Email::SecureMessageId.decode(wrapped, secret: SECRET, now: NOW)
    assert_equal 42, decoded["thread_id"]
  end

  def test_decode_rejects_tampered_payload
    id = encode_fixture
    tampered = id.sub(/\.[A-Za-z0-9_\-]+\./, ".AAAA.")
    assert_raises(Cloudflare::Email::SecureMessageId::InvalidToken) do
      Cloudflare::Email::SecureMessageId.decode(tampered, secret: SECRET, now: NOW)
    end
  end

  def test_decode_rejects_wrong_secret
    id = encode_fixture
    assert_raises(Cloudflare::Email::SecureMessageId::InvalidToken) do
      Cloudflare::Email::SecureMessageId.decode(id, secret: "different", now: NOW)
    end
  end

  def test_decode_rejects_expired
    id = encode_fixture
    assert_raises(Cloudflare::Email::SecureMessageId::InvalidToken) do
      Cloudflare::Email::SecureMessageId.decode(id, secret: SECRET, now: NOW + (31 * 24 * 60 * 60))
    end
  end

  def test_decode_rejects_future
    id = encode_fixture
    assert_raises(Cloudflare::Email::SecureMessageId::InvalidToken) do
      Cloudflare::Email::SecureMessageId.decode(id, secret: SECRET, now: NOW - (10 * 60))
    end
  end

  def test_decode_rejects_malformed
    ["", "plain@example.com", "msg.onlyone@example.com", "nobits@", "<>"].each do |bad|
      assert_raises(Cloudflare::Email::SecureMessageId::InvalidToken) do
        Cloudflare::Email::SecureMessageId.decode(bad, secret: SECRET, now: NOW)
      end
    end
  end

  def test_match_heuristic
    assert Cloudflare::Email::SecureMessageId.match?(encode_fixture)
    assert Cloudflare::Email::SecureMessageId.match?("<#{encode_fixture}>")
    refute Cloudflare::Email::SecureMessageId.match?("CAL61HnmMJ.QBqdj.3tu4DdAL@mail.gmail.com")
    refute Cloudflare::Email::SecureMessageId.match?("plain@example.com")
  end

  def test_uses_full_hmac_length
    id = encode_fixture
    _local, _domain = id.split("@", 2)
    _pfx, _b64, mac = id.split("@").first.split(".", 3)
    assert_equal 64, mac.length
  end
end
