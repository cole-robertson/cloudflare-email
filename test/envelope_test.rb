require "test_helper"
require "cloudflare/email/envelope"
require "cloudflare/email/verification"

class EnvelopeTest < Minitest::Test
  Envelope = Cloudflare::Email::Envelope
  Verification = Cloudflare::Email::Verification

  def test_round_trip_and_null_reverse_path
    assert_equal({ "from" => "", "to" => "bcc@example.com" }, Envelope.decode(Envelope.encode(from: "", to: "bcc@example.com")))
    assert_equal({ "from" => "sender@example.com", "to" => "To+tag@Example.com" },
      Envelope.decode(Envelope.encode(from: "sender@example.com", to: "To+tag@Example.com")))
  end

  def test_rejects_invalid_schema_addresses_and_encoding
    values = [nil, [], {}, { "from" => "x@example.com", "to" => [] },
      { "from" => "", "to" => "x@example.com", "extra" => true }]
    invalid_addresses = ["", "Name <x@example.com>", "x\r\n@example.com", "x@-bad.example", "x@a..com", "a" * 65 + "@example.com", "é@example.com", ".x@example.com", "x.@example.com"]
    invalid_addresses.each { |to| values << { "from" => "", "to" => to } }
    values.each { |value| assert_nil Envelope.decode(Cloudflare::Email::Signing.base64url_encode(JSON.generate(value))) }
    ["x" * 1025, "abc=", "!", "a", "_w"].each { |value| assert_nil Envelope.decode(value) }
  end

  def test_v2_covers_envelope_and_original_binary_body
    envelope = Envelope.encode(from: "sender@example.com", to: "bcc@example.com")
    body = "MIME\r\n\r\n".b + (0..255).to_a.pack("C*")
    options = { secret: "fixture-secret", body: body, timestamp: "1750000000", version: "2", envelope: envelope }
    signature = Verification.sign(**options)
    assert_equal :ok, Verification.verify(**options, signature: signature, now: 1750000000)
    changed_envelope = Envelope.encode(from: "sender@example.com", to: "other@example.com")
    assert_equal :bad_signature, Verification.verify(**options.merge(envelope: changed_envelope), signature: signature, now: 1750000000)
    assert_equal :bad_signature, Verification.verify(**options.merge(body: body + "changed"), signature: signature, now: 1750000000)
    assert_equal :bad_signature, Verification.verify(**options.merge(version: nil), signature: signature, now: 1750000000)
    assert_equal :bad_signature, Verification.verify(**options.merge(envelope: nil), signature: signature, now: 1750000000)
    assert_equal :bad_signature, Verification.verify(**options.merge(version: "3"), signature: signature, now: 1750000000)
  end

  def test_legacy_verification_does_not_authenticate_extra_envelope_headers
    options = { secret: "fixture", body: "raw", timestamp: "1750000000" }
    signature = Verification.sign(**options)
    assert_equal :ok, Verification.verify(**options, envelope: "untrusted", signature: signature, now: 1750000000)
    assert_equal :bad_signature, Verification.verify(**options, version: "2", envelope: Envelope.encode(from: "", to: "x@example.com"), signature: signature, now: 1750000000)
  end
end
