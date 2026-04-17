require "cloudflare/email/signing"

module Cloudflare
  module Email
    # HMAC verification for inbound webhook signatures from the bundled
    # Cloudflare Email Worker. Pure-Ruby and Rails-free so it can be
    # unit-tested in isolation.
    #
    # Worker signs: HMAC-SHA256(secret, "{timestamp}.{raw_body}")
    # Worker sends:
    #   X-CF-Email-Timestamp: <unix seconds>
    #   X-CF-Email-Signature: <hex digest>
    module Verification
      DEFAULT_WINDOW = 5 * 60 # seconds

      # Returns :ok, :bad_signature, or :stale.
      # Returns :bad_signature for any malformed input.
      def self.verify(secret:, body:, timestamp:, signature:, window: DEFAULT_WINDOW, now: Time.now.to_i)
        return :bad_signature if blank?(secret) || blank?(body) || blank?(timestamp) || blank?(signature)

        ts = begin
          Integer(timestamp.to_s, 10)
        rescue ArgumentError, TypeError
          return :bad_signature
        end

        return :stale if (now - ts).abs > window

        expected = Signing.hmac_hex(secret, "#{ts}.#{body}")
        return :bad_signature unless Signing.secure_compare(expected, signature.to_s)

        :ok
      end

      def self.sign(secret:, body:, timestamp:)
        Signing.hmac_hex(secret, "#{timestamp}.#{body}")
      end

      def self.blank?(v)
        v.nil? || v.to_s.empty?
      end
    end
  end
end
