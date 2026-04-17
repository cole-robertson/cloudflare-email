require "test_helper"
require "cloudflare/email/verification"

# Unit tests for HMAC verification — the heart of the ingress controller.
# A full controller integration test requires booting a Rails app with
# ActionMailbox + ActiveStorage migrations; that's covered by the example
# Rails app, not here.
class VerificationTest < Minitest::Test
  SECRET = "test-ingress-secret-very-long-string-1234567890abcdef".freeze
  BODY   = "From: a@b.com\r\nTo: c@d.com\r\nSubject: Hi\r\n\r\nbody\r\n".freeze

  def now; 1_750_000_000; end

  def sig_for(ts, body = BODY, secret = SECRET)
    Cloudflare::Email::Verification.sign(secret: secret, body: body, timestamp: ts)
  end

  def test_ok_with_fresh_timestamp_and_valid_signature
    ts  = now.to_s
    sig = sig_for(ts)
    assert_equal :ok, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: BODY, timestamp: ts, signature: sig, now: now,
    )
  end

  def test_bad_signature
    ts = now.to_s
    assert_equal :bad_signature, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: BODY, timestamp: ts, signature: "deadbeef" * 8, now: now,
    )
  end

  def test_signature_with_wrong_secret_fails
    ts = now.to_s
    sig = sig_for(ts, BODY, "wrong-secret")
    assert_equal :bad_signature, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: BODY, timestamp: ts, signature: sig, now: now,
    )
  end

  def test_signature_with_tampered_body_fails
    ts = now.to_s
    sig = sig_for(ts)
    assert_equal :bad_signature, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: "tampered " + BODY, timestamp: ts, signature: sig, now: now,
    )
  end

  def test_stale_timestamp_outside_window
    ts = (now - 600).to_s
    sig = sig_for(ts)
    assert_equal :stale, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: BODY, timestamp: ts, signature: sig, now: now,
    )
  end

  def test_future_timestamp_outside_window
    ts = (now + 600).to_s
    sig = sig_for(ts)
    assert_equal :stale, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: BODY, timestamp: ts, signature: sig, now: now,
    )
  end

  def test_just_inside_window_ok
    ts  = (now - Cloudflare::Email::Verification::DEFAULT_WINDOW).to_s
    sig = sig_for(ts)
    assert_equal :ok, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: BODY, timestamp: ts, signature: sig, now: now,
    )
  end

  def test_missing_secret
    ts = now.to_s
    assert_equal :bad_signature, Cloudflare::Email::Verification.verify(
      secret: "", body: BODY, timestamp: ts, signature: sig_for(ts), now: now,
    )
  end

  def test_missing_signature_header
    ts = now.to_s
    assert_equal :bad_signature, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: BODY, timestamp: ts, signature: nil, now: now,
    )
  end

  def test_missing_timestamp_header
    assert_equal :bad_signature, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: BODY, timestamp: nil, signature: "abc", now: now,
    )
  end

  def test_non_numeric_timestamp
    assert_equal :bad_signature, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: BODY, timestamp: "not-a-number", signature: "abc", now: now,
    )
  end

  def test_round_trip_sign_and_verify
    ts = now.to_s
    sig = Cloudflare::Email::Verification.sign(secret: SECRET, body: BODY, timestamp: ts)
    assert_equal :ok, Cloudflare::Email::Verification.verify(
      secret: SECRET, body: BODY, timestamp: ts, signature: sig, now: now,
    )
  end
end
