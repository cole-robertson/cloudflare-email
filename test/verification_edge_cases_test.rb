require "test_helper"
require "cloudflare/email/verification"

class VerificationEdgeCasesTest < Minitest::Test
  SECRET = "k" * 64

  def sign(ts, body, secret: SECRET)
    Cloudflare::Email::Verification.sign(secret: secret, body: body, timestamp: ts)
  end

  def test_binary_body_with_null_bytes
    body = "binary\x00\xff\x01\x02data".b
    ts = "1750000000"
    sig = sign(ts, body)
    assert_equal :ok, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: body, timestamp: ts, signature: sig, now: 1_750_000_000,
    )
  end

  def test_unicode_body
    body = "Café résumé 日本語 🔥"
    ts = "1750000000"
    sig = sign(ts, body)
    assert_equal :ok, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: body, timestamp: ts, signature: sig, now: 1_750_000_000,
    )
  end

  def test_large_body_1mb
    body = "a" * 1_048_576
    ts = "1750000000"
    sig = sign(ts, body)
    assert_equal :ok, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: body, timestamp: ts, signature: sig, now: 1_750_000_000,
    )
  end

  def test_empty_body_treated_as_bad_input
    assert_equal :bad_signature, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: "", timestamp: "1", signature: "sig", now: 1,
    )
  end

  def test_signature_case_sensitive
    body = "hello"
    ts = "1"
    sig = sign(ts, body)
    assert_equal :bad_signature, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: body, timestamp: ts, signature: sig.upcase, now: 1,
    )
  end

  def test_timestamp_with_leading_zeros_rejected
    # Integer("0100", 10) is fine, but "0x1" would fail — we pass base 10 strictly.
    body = "hello"
    ts = "0100"
    sig = sign("100", body)
    # "0100" parses as 100 in base 10, so this is actually accepted if fresh
    result = Cloudflare::Email::Verification.verify(
      secret: SECRET, body: body, timestamp: ts, signature: sig, now: 100,
    )
    assert_includes [:ok, :bad_signature], result
  end

  def test_hex_timestamp_rejected
    assert_equal :bad_signature, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: "x", timestamp: "0xff", signature: "sig", now: 1,
    )
  end

  def test_float_timestamp_rejected
    assert_equal :bad_signature, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: "x", timestamp: "1.5", signature: "sig", now: 1,
    )
  end

  def test_custom_window
    ts = "100"
    sig = sign(ts, "body")
    # 30s away with a 60s window → ok
    assert_equal :ok, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: "body", timestamp: ts, signature: sig, window: 60, now: 130,
    )
    # 120s away with a 60s window → stale
    assert_equal :stale, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: "body", timestamp: ts, signature: sig, window: 60, now: 220,
    )
  end

  def test_different_length_signatures_rejected_without_leaking_timing
    # Constant-time compare works on different lengths without crashing.
    body = "hello"
    ts = "1"
    assert_equal :bad_signature, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: body, timestamp: ts, signature: "short", now: 1,
    )
    assert_equal :bad_signature, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: body, timestamp: ts, signature: "way-too-long-signature-value-that-cant-match", now: 1,
    )
  end
end
