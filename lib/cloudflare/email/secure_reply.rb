require "base64"
require "json"
require "openssl"
require "securerandom"

module Cloudflare
  module Email
    # Signed reply-to addresses, inspired by the Cloudflare Agents SDK's
    # `createSecureReplyEmailResolver`.
    #
    # When you send an email to a user and want their reply to be securely
    # matched back to the original thread (user, tenant, whatever), put a
    # SecureReply-encoded address in your `reply-to:` header instead of your
    # literal inbound address. The encoded address embeds:
    #
    #   - an arbitrary payload you choose (e.g. { t: "abc123" })
    #   - an issued-at timestamp (4-byte binary offset from 2026-01-01)
    #   - a truncated HMAC-SHA256 over the base64-encoded packed bytes
    #
    # When the reply arrives at your ingress, decode it. Invalid / expired /
    # tampered tokens raise `InvalidToken`. Valid ones return the payload.
    #
    # ## Address format
    #
    #   {local_part}.{base64url(packed)}.{hmac_hex_32}@{domain}
    #
    # where `packed` is `[4 bytes unsigned iat offset][JSON payload bytes]`.
    # The whole local part must fit within RFC 5321's 64-char limit (Cloudflare
    # enforces this). Stay small — use short keys and short values. For big
    # state, store it server-side and encode only a lookup id (see below).
    #
    # ## Usage (outbound)
    #
    #   reply_to = Cloudflare::Email::SecureReply.encode(
    #     payload: { t: thread.id.to_s },  # keep it tiny
    #     domain:  "in.yourdomain.com",
    #     secret:  Rails.application.credentials.dig(:cloudflare, :reply_secret),
    #   )
    #
    # ## Usage (inbound)
    #
    #   class SupportMailbox < ApplicationMailbox
    #     def process
    #       payload = Cloudflare::Email::SecureReply.decode(
    #         mail.to.first,
    #         secret: Rails.application.credentials.dig(:cloudflare, :reply_secret),
    #       )
    #       Thread.find(payload["t"]).reply_from(mail)
    #     rescue Cloudflare::Email::SecureReply::InvalidToken
    #       bounce_with BounceMailer.invalid_reply(inbound_email)
    #     end
    #   end
    module SecureReply
      InvalidToken    = Class.new(Cloudflare::Email::Error)
      PayloadTooLarge = Class.new(Cloudflare::Email::Error)

      DEFAULT_LOCAL_PART = "reply".freeze
      DEFAULT_MAX_AGE    = 30 * 24 * 60 * 60 # 30 days
      HMAC_HEX_LENGTH    = 32                # truncated 128-bit MAC
      MAX_LOCAL_PART     = 64                # RFC 5321
      EPOCH_OFFSET       = Time.utc(2026, 1, 1).to_i.freeze  # compact timestamps

      class << self
        def encode(payload:, domain:, secret:, local_part: DEFAULT_LOCAL_PART, now: Time.now.to_i)
          raise ArgumentError, "secret must not be empty" if secret.to_s.empty?
          raise ArgumentError, "domain must not be empty" if domain.to_s.empty?

          iat_offset = now.to_i - EPOCH_OFFSET
          raise ArgumentError, "timestamp out of 32-bit range" if iat_offset.negative? || iat_offset >= (1 << 32)

          packed = [iat_offset].pack("N") + JSON.generate(payload)
          b64    = base64url_encode(packed)
          mac    = hmac(secret, b64)[0, HMAC_HEX_LENGTH]

          local = "#{local_part}.#{b64}.#{mac}"
          if local.bytesize > MAX_LOCAL_PART
            raise PayloadTooLarge,
              "payload yields #{local.bytesize}-char local part; RFC 5321 limit is #{MAX_LOCAL_PART}. " \
              "Use a smaller payload (or store state server-side and encode a lookup id instead)."
          end

          "#{local}@#{domain}"
        end

        def decode(address, secret:, max_age: DEFAULT_MAX_AGE, now: Time.now.to_i)
          raise InvalidToken, "address is empty" if address.to_s.empty?

          local, domain = address.to_s.split("@", 2)
          raise InvalidToken, "missing @ in address" unless local && domain

          _prefix, b64, mac = local.split(".", 3)
          raise InvalidToken, "malformed token" unless b64 && mac && !b64.empty? && !mac.empty?

          expected = hmac(secret, b64)[0, HMAC_HEX_LENGTH]
          raise InvalidToken, "signature mismatch" unless secure_compare(expected, mac)

          packed = begin
            base64url_decode(b64)
          rescue StandardError
            raise InvalidToken, "base64 decode failed"
          end
          raise InvalidToken, "truncated packed bytes" if packed.bytesize < 4

          iat_offset = packed.byteslice(0, 4).unpack1("N")
          iat        = iat_offset + EPOCH_OFFSET
          payload_json = packed.byteslice(4..)

          raise InvalidToken, "token expired"                 if now - iat > max_age
          raise InvalidToken, "token timestamp in the future" if iat - now > 5 * 60

          JSON.parse(payload_json.to_s)
        rescue JSON::ParserError
          raise InvalidToken, "payload not valid JSON"
        end

        # Cheap heuristic — does this look like a SecureReply address at all?
        # Useful for ApplicationMailbox routing.
        def match?(address, local_part: DEFAULT_LOCAL_PART)
          local, domain = address.to_s.split("@", 2)
          return false unless domain
          prefix, b64, mac = local.split(".", 3)
          return false unless prefix && b64 && mac
          prefix == local_part && !b64.empty? && mac.match?(/\A[0-9a-f]{#{HMAC_HEX_LENGTH}}\z/)
        end

        private

        def hmac(secret, data)
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
end
