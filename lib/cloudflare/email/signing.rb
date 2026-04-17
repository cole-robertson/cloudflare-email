require "base64"
require "openssl"

module Cloudflare
  module Email
    # Shared cryptographic helpers: HMAC-SHA256, constant-time compare,
    # base64url encoding. Used by Verification (ingress HMAC) and
    # SecureMessageId (signed Message-IDs). Keeps every crypto primitive in
    # one place so the hash algorithm, encoding choice, and compare function
    # can't drift between call sites.
    module Signing
      module_function

      def hmac_hex(secret, data)
        OpenSSL::HMAC.hexdigest("SHA256", secret, data)
      end

      def secure_compare(a, b)
        if defined?(ActiveSupport::SecurityUtils)
          ActiveSupport::SecurityUtils.secure_compare(a, b)
        else
          return false if a.bytesize != b.bytesize
          OpenSSL.fixed_length_secure_compare(a, b)
        end
      end

      def base64url_encode(bytes)
        Base64.urlsafe_encode64(bytes, padding: false)
      end

      def base64url_decode(str)
        padding = (4 - str.length % 4) % 4
        Base64.urlsafe_decode64(str + ("=" * padding))
      end
    end
  end
end
