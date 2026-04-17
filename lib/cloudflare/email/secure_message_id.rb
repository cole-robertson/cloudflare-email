require "json"
require "cloudflare/email/signing"

module Cloudflare
  module Email
    # Signed outbound Message-IDs for reply authentication.
    #
    # Sign the outbound Message-ID with HMAC-SHA256. The recipient's reply
    # naturally carries the signed id in `In-Reply-To:`, which your mailbox
    # verifies and decodes to recover the original thread state.
    #
    # See README's "Signed replies" section for a full usage example.
    module SecureMessageId
      InvalidToken = Class.new(Cloudflare::Email::Error)

      DEFAULT_PREFIX  = "msg".freeze
      DEFAULT_MAX_AGE = 30 * 24 * 60 * 60   # 30 days
      EPOCH_OFFSET    = Time.utc(2026, 1, 1).to_i.freeze

      class << self
        # Build a signed Message-ID carrying `payload`. Returns the bare
        # Message-ID without angle brackets — SMTP/Mail adds them.
        def encode(payload:, domain:, secret:, prefix: DEFAULT_PREFIX, now: Time.now.to_i)
          raise ArgumentError, "secret must not be empty" if secret.to_s.empty?
          raise ArgumentError, "domain must not be empty" if domain.to_s.empty?

          iat_offset = now.to_i - EPOCH_OFFSET
          raise ArgumentError, "timestamp out of 32-bit range" if iat_offset.negative? || iat_offset >= (1 << 32)

          packed = [iat_offset].pack("N") + JSON.generate(payload)
          b64    = Signing.base64url_encode(packed)
          mac    = Signing.hmac_hex(secret, b64)

          "#{prefix}.#{b64}.#{mac}@#{domain}"
        end

        # Decode a Message-ID produced by encode. Accepts `<bracketed>` form
        # too. Returns parsed payload or raises InvalidToken.
        def decode(message_id, secret:, max_age: DEFAULT_MAX_AGE, now: Time.now.to_i)
          raise InvalidToken, "message-id is empty" if message_id.to_s.empty?

          id = strip_brackets(message_id.to_s).strip
          local, domain = id.split("@", 2)
          raise InvalidToken, "missing @ in message-id" unless local && domain

          _prefix, b64, mac = local.split(".", 3)
          raise InvalidToken, "malformed message-id" unless b64 && mac && !b64.empty? && !mac.empty?

          expected = Signing.hmac_hex(secret, b64)
          raise InvalidToken, "signature mismatch" unless Signing.secure_compare(expected, mac)

          packed = begin
            Signing.base64url_decode(b64)
          rescue StandardError
            raise InvalidToken, "base64 decode failed"
          end
          raise InvalidToken, "truncated packed bytes" if packed.bytesize < 4

          iat_offset   = packed.byteslice(0, 4).unpack1("N")
          iat          = iat_offset + EPOCH_OFFSET
          payload_json = packed.byteslice(4..)

          raise InvalidToken, "token expired"                 if now - iat > max_age
          raise InvalidToken, "token timestamp in the future" if iat - now > 5 * 60

          JSON.parse(payload_json.to_s)
        rescue JSON::ParserError
          raise InvalidToken, "payload not valid JSON"
        end

        # Cheap heuristic — does this look like one of our signed Message-IDs?
        def match?(message_id, prefix: DEFAULT_PREFIX)
          id = strip_brackets(message_id.to_s).strip
          local, domain = id.split("@", 2)
          return false unless local && domain
          p, b64, mac = local.split(".", 3)
          return false unless p && b64 && mac
          p == prefix && !b64.empty? && mac.match?(/\A[0-9a-f]{64}\z/)
        end

        private

        def strip_brackets(s)
          s.start_with?("<") && s.end_with?(">") ? s[1..-2] : s
        end
      end
    end
  end
end
