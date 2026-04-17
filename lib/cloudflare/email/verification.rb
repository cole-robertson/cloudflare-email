require "openssl"

module Cloudflare
  module Email
    # HMAC verification for inbound webhook signatures from the bundled Cloudflare
    # Email Worker. Pure-Ruby and Rails-free so it can be unit-tested in isolation.
    #
    # The Worker signs:  HMAC-SHA256(secret, "{timestamp}.{raw_body}")
    # And sends:
    #   X-CF-Email-Timestamp: <unix seconds>
    #   X-CF-Email-Signature: <hex digest>
    module Verification
      DEFAULT_WINDOW = 5 * 60 # seconds

      # Returns :ok, :bad_signature, or :stale.
      # Returns :bad_signature for any malformed input (missing pieces, bad timestamp parse).
      def self.verify(secret:, body:, timestamp:, signature:, window: DEFAULT_WINDOW, now: Time.now.to_i)
        return :bad_signature if blank?(secret) || blank?(body) || blank?(timestamp) || blank?(signature)

        ts = begin
          Integer(timestamp.to_s, 10)
        rescue ArgumentError, TypeError
          return :bad_signature
        end

        return :stale if (now - ts).abs > window

        expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{ts}.#{body}")
        return :bad_signature unless secure_compare(expected, signature.to_s)

        :ok
      end

      def self.sign(secret:, body:, timestamp:)
        OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")
      end

      def self.blank?(v)
        v.nil? || v.to_s.empty?
      end

      # Constant-time compare. Uses ActiveSupport when available, falls back to OpenSSL.
      def self.secure_compare(a, b)
        if defined?(ActiveSupport::SecurityUtils)
          ActiveSupport::SecurityUtils.secure_compare(a, b)
        else
          return false if a.bytesize != b.bytesize
          OpenSSL.fixed_length_secure_compare(a, b)
        end
      end
    end
  end
end
