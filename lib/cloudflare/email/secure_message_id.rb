require "base64"
require "json"
require "openssl"

module Cloudflare
  module Email
    # Signed outbound Message-IDs for reply authentication.
    #
    # Sign the outbound Message-ID with HMAC-SHA256. The recipient's reply
    # naturally carries the signed id in `In-Reply-To:`, which your mailbox
    # verifies and decodes to recover the original thread state.
    #
    # This mirrors the spirit of Cloudflare's JS SDK
    # `createSecureReplyEmailResolver` pattern without requiring Durable
    # Object storage — state is encoded in the Message-ID itself.
    #
    # ## Address format
    #
    #   {prefix}.{base64url(packed)}.{timestamp}.{hmac_hex_64}@{domain}
    #
    # where `packed` is `[4 bytes unsigned iat offset][JSON payload bytes]`.
    # The total can be up to ~998 chars — no practical size constraint.
    #
    # ## Usage (outbound)
    #
    #   class AgentMailer < ApplicationMailer
    #     def ping(thread)
    #       signed_id = Cloudflare::Email::SecureMessageId.encode(
    #         payload: { thread_id: thread.id, user_id: thread.user_id, kind: "ping" },
    #         domain:  "mail.yourdomain.com",
    #         secret:  Rails.application.credentials.dig(:cloudflare, :reply_secret),
    #       )
    #       mail(
    #         to: thread.user.email,
    #         from: "agent@mail.yourdomain.com",
    #         reply_to: "agent@in.yourdomain.com",
    #         subject: "Re: #{thread.title}",
    #         message_id: signed_id,
    #       ) { |f| f.text { render plain: "..." } }
    #     end
    #   end
    #
    # ## Usage (inbound — read `In-Reply-To:`)
    #
    #   class AgentMailbox < ApplicationMailbox
    #     def process
    #       ref = mail.in_reply_to || mail.references&.first
    #       if ref && Cloudflare::Email::SecureMessageId.match?(ref)
    #         payload = Cloudflare::Email::SecureMessageId.decode(
    #           ref,
    #           secret: Rails.application.credentials.dig(:cloudflare, :reply_secret),
    #         )
    #         Thread.find(payload["thread_id"]).ingest(mail)
    #       end
    #     rescue Cloudflare::Email::SecureMessageId::InvalidToken => e
    #       Rails.logger.warn("Invalid signed message-id: #{e.message}")
    #     end
    #   end
    module SecureMessageId
      InvalidToken = Class.new(Cloudflare::Email::Error)

      DEFAULT_PREFIX  = "msg".freeze
      DEFAULT_MAX_AGE = 30 * 24 * 60 * 60   # 30 days
      HMAC_HEX_LENGTH = 64                  # full SHA-256 — no size constraint here
      EPOCH_OFFSET    = Time.utc(2026, 1, 1).to_i.freeze

      class << self
        # Build a signed Message-ID that carries `payload`. Returns the bare
        # Message-ID *without* angle brackets — the Mail gem (and SMTP) will
        # add them when writing the header. When setting
        # `mail.message_id = encode(...)`, Rails handles it correctly.
        def encode(payload:, domain:, secret:, prefix: DEFAULT_PREFIX, now: Time.now.to_i)
          raise ArgumentError, "secret must not be empty" if secret.to_s.empty?
          raise ArgumentError, "domain must not be empty" if domain.to_s.empty?

          iat_offset = now.to_i - EPOCH_OFFSET
          raise ArgumentError, "timestamp out of 32-bit range" if iat_offset.negative? || iat_offset >= (1 << 32)

          packed = [iat_offset].pack("N") + JSON.generate(payload)
          b64    = base64url_encode(packed)
          # The HMAC covers only the base64 payload — timestamp is IN the
          # packed bytes, so it gets signed along with everything else.
          mac    = hmac(secret, b64)

          "#{prefix}.#{b64}.#{mac}@#{domain}"
        end

        # Decode a Message-ID produced by `encode`. Accepts both bare
        # message-ids and angle-bracketed forms ("<id@domain>"). Returns
        # the parsed payload or raises InvalidToken.
        def decode(message_id, secret:, max_age: DEFAULT_MAX_AGE, now: Time.now.to_i)
          raise InvalidToken, "message-id is empty" if message_id.to_s.empty?

          id = strip_brackets(message_id.to_s).strip
          local, domain = id.split("@", 2)
          raise InvalidToken, "missing @ in message-id" unless local && domain

          _prefix, b64, mac = local.split(".", 3)
          raise InvalidToken, "malformed message-id" unless b64 && mac && !b64.empty? && !mac.empty?

          expected = hmac(secret, b64)
          raise InvalidToken, "signature mismatch" unless secure_compare(expected, mac)

          packed = begin
            base64url_decode(b64)
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
          p == prefix && !b64.empty? && mac.match?(/\A[0-9a-f]{#{HMAC_HEX_LENGTH}}\z/)
        end

        private

        def strip_brackets(s)
          s.start_with?("<") && s.end_with?(">") ? s[1..-2] : s
        end

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
