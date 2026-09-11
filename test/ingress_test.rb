require_relative "test_helper"
require "cloudflare/email/ingress"
require "stringio"

class IngressTest < Minitest::Test
  Ingress = Cloudflare::Email::Ingress
  Metadata = Cloudflare::Email::ProviderMetadata
  Verification = Cloudflare::Email::Verification
  Envelope = Cloudflare::Email::Envelope
  SECRET = "worker-test-secret-abc123"
  NOW = 1_750_000_000
  RAW = [0, 255, 13, 10, 128].pack("C*").freeze
  PROVIDER = {"source" => "cloudflare", "data" => {"note" => "Résumé ☁", "spf" => "pass", "score" => 0.5, "flags" => [true, nil]}}.freeze
  ENCODED = "eyJzb3VyY2UiOiJjbG91ZGZsYXJlIiwiZGF0YSI6eyJub3RlIjoiUsOpc3Vtw6kg4piBIiwic3BmIjoicGFzcyIsInNjb3JlIjowLjUsImZsYWdzIjpbdHJ1ZSxudWxsXX19"
  NODE_SIGNATURE = "d4e5ed55306e1619b5c40f3ec5dfea44a3131ad422a22b49ffb042069f6b720f"

  class ChunkedBody
    attr_reader :requested

    def initialize(raw, chunk_size: nil)
      @io = StringIO.new(raw)
      @chunk_size = chunk_size
      @requested = []
    end

    def read(limit)
      @requested << limit
      @io.read(@chunk_size ? [limit, @chunk_size].min : limit)
    end
  end

  def headers(raw: RAW, metadata: ENCODED, timestamp: NOW.to_s, from: "sender@external.test", to: "inbox@trial.test")
    envelope = Envelope.encode(from: from, to: to)
    version = metadata ? "3" : "2"
    result = {
      "X-CF-Email-Timestamp" => timestamp,
      "X-CF-Email-Envelope" => envelope,
      "X-CF-Email-Signature-Version" => version,
      "X-CF-Email-Signature" => Verification.sign(secret: SECRET, body: raw,
        timestamp: timestamp, envelope: envelope, version: version, metadata: metadata)
    }
    result["X-CF-Email-Metadata"] = metadata if metadata
    result
  end

  def verify(request_headers = headers, body: RAW, **options)
    Ingress.verify(secret: SECRET, headers: request_headers, body: body, now: NOW, **options)
  end

  def encode(value)
    Cloudflare::Email::Signing.base64url_encode(JSON.generate(value))
  end

  def test_shared_worker_vector_preserves_binary_mime_and_unicode_metadata
    request_headers = headers.merge("X-CF-Email-Signature" => NODE_SIGNATURE)
    result = verify(request_headers)
    assert_equal :ok, result.status
    assert_equal RAW, result.message.body
    assert_equal Encoding::BINARY, result.message.body.encoding
    assert_equal 5, result.bytes
    assert_equal PROVIDER, result.message.provider_metadata
    assert_equal ENCODED, Metadata.encode(source: PROVIDER["source"], data: PROVIDER["data"])
    assert_equal 3, result.message.storage_metadata.fetch(Envelope::METADATA_KEY).fetch("version")
    assert_equal 3, result.message.storage_metadata.fetch(Metadata::METADATA_KEY).fetch("signature_version")
  end

  def test_v2_retains_existing_checksum_and_has_no_provider_metadata
    result = verify(headers(metadata: nil))
    assert_equal :ok, result.status
    assert_nil result.message.provider_metadata
    refute result.message.storage_metadata.key?(Metadata::METADATA_KEY)
    assert_equal Digest::SHA256.hexdigest("v2\0inbox@trial.test\0".b + RAW), result.message.message_checksum
  end

  def test_rack_environment_header_names_are_supported
    rack_headers = headers.transform_keys { |key| "HTTP_#{key.upcase.tr('-', '_')}" }
    assert_equal :ok, verify(rack_headers).status
  end

  def test_preflight_rejects_invalid_stale_and_mismatched_versions_without_reading
    alterations = [
      ["X-CF-Email-Signature", "invalid", :bad_signature],
      ["X-CF-Email-Timestamp", (NOW - 301).to_s, :stale],
      ["X-CF-Email-Envelope", "invalid", :bad_signature],
      ["X-CF-Email-Metadata", nil, :bad_signature],
      ["X-CF-Email-Signature-Version", "2", :bad_signature],
      ["X-CF-Email-Signature-Version", "1", :bad_signature]
    ]
    alterations.each do |name, value, expected|
      body = ChunkedBody.new(RAW)
      result = verify(headers.merge(name => value), body: body)
      assert_equal expected, result.status
      assert_nil result.message
      assert_empty body.requested
    end
  end

  def test_malformed_metadata_is_rejected_before_body_read
    invalid = [
      "not+base64", "#{ENCODED}=", "a" * (Metadata::MAX_ENCODED_BYTES + 1),
      encode({"source" => "a", "data" => []}),
      encode({"source" => "a\n", "data" => {}}),
      encode(PROVIDER.merge("extra" => true)),
      Cloudflare::Email::Signing.base64url_encode("\xff".b),
      Cloudflare::Email::Signing.base64url_encode('{"source":"a","data":{"x":"\\ud800"}}')
    ]
    nested = {}
    7.times { nested = {"child" => nested} }
    invalid << encode({"source" => "a", "data" => nested})
    invalid.each do |metadata|
      body = ChunkedBody.new(RAW)
      assert_equal :bad_signature, verify(headers.merge("X-CF-Email-Metadata" => metadata), body: body).status
      assert_empty body.requested
    end
  end

  def test_valid_but_tampered_metadata_and_body_fail_authentication
    tampered = encode(PROVIDER.merge("data" => {"spf" => "fail"}))
    result = verify(headers.merge("X-CF-Email-Metadata" => tampered))
    assert_equal :bad_signature, result.status
    assert_nil result.message
    assert_equal :bad_signature, verify(body: RAW + "changed").status
  end

  def test_declared_oversize_is_rejected_before_read_and_understated_size_does_not_bypass_limit
    body = ChunkedBody.new(RAW)
    assert_equal :too_large, verify(body: body, content_length: "6", max_email_bytes: 5).status
    assert_empty body.requested
    oversized = RAW + "extra"
    body = ChunkedBody.new(oversized)
    assert_equal :too_large, verify(headers(raw: oversized), body: body, content_length: "1", max_email_bytes: 5).status
    assert_equal [6], body.requested
    assert_equal :too_large, verify(headers(raw: oversized), body: oversized, max_email_bytes: 5).status
  end

  def test_short_io_reads_are_accumulated_within_the_limit
    body = ChunkedBody.new(RAW, chunk_size: 2)
    assert_equal :ok, verify(body: body, max_email_bytes: RAW.bytesize).status
    assert_operator body.requested.length, :>, 1
    assert body.requested.all? { |limit| limit.between?(1, RAW.bytesize + 1) }
    oversized = RAW + "extra"
    assert_equal :too_large, verify(headers(raw: oversized), body: ChunkedBody.new(oversized, chunk_size: 2), max_email_bytes: 5).status
  end

  def test_invalid_size_configuration_and_length_do_not_read_body
    body = ChunkedBody.new(RAW)
    [0, -1, "5", nil].each do |limit|
      assert_raises(ArgumentError) { verify(body: body, max_email_bytes: limit) }
    end
    ["invalid", "-1"].each do |length|
      assert_equal :bad_signature, verify(body: body, content_length: length).status
    end
    assert_empty body.requested
  end

  def test_verified_result_and_nested_metadata_are_immutable_copies
    original = RAW.dup
    result = verify(body: original)
    original.clear
    assert_equal RAW, result.message.body
    assert result.frozen?
    assert result.message.frozen?
    assert_raises(FrozenError) { result.message.body << "changed" }
    assert_raises(FrozenError) { result.message.envelope["to"].replace("other@example.test") }
    assert_raises(FrozenError) { result.message.provider_metadata["data"]["flags"] << false }
    assert_raises(FrozenError) { result.message.storage_metadata[Metadata::METADATA_KEY]["data"]["note"].clear }
  end

  def test_retries_and_reordered_objects_deduplicate_but_new_assertions_do_not
    original = verify.message.message_checksum
    reordered = {"data" => PROVIDER["data"].to_a.reverse.to_h, "source" => "cloudflare"}
    retry_headers = headers(metadata: encode(reordered), timestamp: (NOW + 1).to_s)
    assert_equal original, verify(retry_headers).message.message_checksum
    refute_equal original, verify(headers(metadata: encode(PROVIDER.merge("source" => "other")))).message.message_checksum
    refute_equal original, verify(headers(from: "other@example.test")).message.message_checksum
    refute_equal original, verify(headers(to: "other@trial.test")).message.message_checksum
    refute_equal original, verify(headers(metadata: nil)).message.message_checksum
  end

  def test_signature_uses_exact_timestamp_header_bytes
    assert_equal :ok, verify(headers(timestamp: "0#{NOW}")).status
  end
end
