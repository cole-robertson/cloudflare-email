require "cloudflare/email/signing"
require "cloudflare/email/envelope"
require "cloudflare/email/provider_metadata"

module Cloudflare
  module Email
    # HMAC verification for inbound webhook signatures from the bundled
    # Cloudflare Email Worker. Pure-Ruby and Rails-free so it can be
    # unit-tested in isolation.
    #
    # Worker signs: HMAC-SHA256(secret, "v2.{timestamp}.{encoded_envelope}.{raw_body}")
    # Worker sends:
    #   X-CF-Email-Timestamp: <unix seconds>
    #   X-CF-Email-Signature: <hex digest>
    #   X-CF-Email-Signature-Version: 2
    #   X-CF-Email-Envelope: <unpadded base64url JSON from/to>
    # Custom integrations may use v3, adding X-CF-Email-Metadata and signing
    # "v3.{timestamp}.{encoded_envelope}.{encoded_metadata}.{raw_body}".
    # v2 rejects metadata headers; v3 requires them. Both require the envelope.
    module Verification
      DEFAULT_WINDOW = 5 * 60 # seconds

      # Returns :ok, :bad_signature, or :stale.
      # Returns :bad_signature for any malformed input.
      def self.verify(secret:, body:, timestamp:, signature:, version: nil, envelope: nil, metadata: nil, window: DEFAULT_WINDOW, now: Time.now.to_i)
        return :bad_signature if blank?(body)
        timestamp = timestamp.to_s if timestamp.is_a?(Integer)
        preflight = verify_headers(secret: secret, timestamp: timestamp, signature: signature,
          version: version, envelope: envelope, metadata: metadata, window: window, now: now)
        return preflight unless preflight == :ok

        expected = sign(secret: secret, body: body, timestamp: timestamp, version: version, envelope: envelope, metadata: metadata)
        return :bad_signature unless Signing.secure_compare(expected, signature)

        :ok
      end

      # Reject malformed/stale requests before the controller reads MIME bytes.
      # This is only a preflight: authentication still requires verify(body: ...).
      def self.verify_headers(secret:, timestamp:, signature:, version:, envelope:, metadata: nil, window: DEFAULT_WINDOW, now: Time.now.to_i)
        return :bad_signature if blank?(secret)
        return :bad_signature unless timestamp.is_a?(String) && /\A[0-9]{1,20}\z/.match?(timestamp)
        return :bad_signature unless signature.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(signature)
        return :bad_signature unless Envelope.decode(envelope)
        return :bad_signature unless valid_metadata_version?(version, metadata)

        ts = begin
          Integer(timestamp.to_s, 10)
        rescue ArgumentError, TypeError
          return :bad_signature
        end

        return :stale if (now - ts).abs > window

        :ok
      end

      def self.sign(secret:, body:, timestamp:, envelope:, version: "2", metadata: nil)
        raise ArgumentError, "invalid signature version or metadata" unless valid_metadata_version?(version, metadata)
        raise ArgumentError, "invalid SMTP envelope" unless Envelope.decode(envelope)
        prefix = version == "3" ? "v3.#{timestamp}.#{envelope}.#{metadata}." : "v2.#{timestamp}.#{envelope}."
        Signing.hmac_hex(secret, prefix.b + body.b)
      end

      def self.valid_metadata_version?(version, metadata)
        (version == "2" && metadata.nil?) || (version == "3" && ProviderMetadata.decode(metadata))
      end

      def self.blank?(v)
        v.nil? || v.to_s.empty?
      end
    end
  end
end
