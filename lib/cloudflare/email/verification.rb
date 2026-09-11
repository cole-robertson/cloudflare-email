require "cloudflare/email/signing"
require "cloudflare/email/envelope"

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
    # The version and authenticated SMTP envelope are required.
    module Verification
      DEFAULT_WINDOW = 5 * 60 # seconds

      # Returns :ok, :bad_signature, or :stale.
      # Returns :bad_signature for any malformed input.
      def self.verify(secret:, body:, timestamp:, signature:, version: nil, envelope: nil, window: DEFAULT_WINDOW, now: Time.now.to_i)
        return :bad_signature if blank?(secret) || blank?(body) || blank?(timestamp) || blank?(signature)
        return :bad_signature unless version == "2" && Envelope.decode(envelope)

        ts = begin
          Integer(timestamp.to_s, 10)
        rescue ArgumentError, TypeError
          return :bad_signature
        end

        return :stale if (now - ts).abs > window

        expected = sign(secret: secret, body: body, timestamp: ts, version: version, envelope: envelope)
        return :bad_signature unless Signing.secure_compare(expected, signature.to_s)

        :ok
      end

      def self.sign(secret:, body:, timestamp:, envelope:, version: "2")
        raise ArgumentError, "unsupported signature version" unless version == "2"
        raise ArgumentError, "invalid SMTP envelope" unless Envelope.decode(envelope)
        prefix = "v2.#{timestamp}.#{envelope}."
        Signing.hmac_hex(secret, prefix.b + body.b)
      end

      def self.blank?(v)
        v.nil? || v.to_s.empty?
      end
    end
  end
end
