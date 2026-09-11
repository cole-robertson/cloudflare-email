require "cloudflare/email/verification"

module Cloudflare
  module Email
    # ActionMailbox ingress for Cloudflare Email Worker forwards.
    #
    # The shipped Worker template signs each forwarded message with HMAC-SHA256
    # over "v2.{timestamp}.{encoded_envelope}.{raw_body}" and sends:
    #   X-CF-Email-Timestamp: <unix seconds>
    #   X-CF-Email-Signature: <hex digest>
    #   X-CF-Email-Signature-Version: 2
    #   X-CF-Email-Envelope: <unpadded base64url JSON from/to>
    # Requests must include the v2 signature and authenticated SMTP envelope.
    #
    # Set the shared secret in Rails credentials under cloudflare.ingress_secret
    # (or in the CLOUDFLARE_INGRESS_SECRET env var) and as the Worker secret
    # INGRESS_SECRET via `wrangler secret put INGRESS_SECRET`.
    class IngressController < ActionMailbox::BaseController
      param_encoding :create, "raw_email", Encoding::ASCII_8BIT

      def create
        ActiveSupport::Notifications.instrument(
          "cloudflare_email.ingress",
          bytes: raw_body.bytesize,
        ) do |payload|
          case Cloudflare::Email::Verification.verify(
                secret:    secret,
                body:      raw_body,
                timestamp: request.headers["X-CF-Email-Timestamp"],
                signature: request.headers["X-CF-Email-Signature"],
                version: request.headers["X-CF-Email-Signature-Version"],
                envelope: request.headers["X-CF-Email-Envelope"],
              )
          when :stale
            payload[:result] = :stale
            head :request_timeout
          when :bad_signature
            payload[:result] = :bad_signature
            head :unauthorized
          when :ok
            inbound = persist_inbound
            payload[:result]     = inbound ? :ok : :duplicate
            payload[:message_id] = inbound&.message_id
            head :ok
          end
        end
      end

      private

      def persist_inbound
        envelope = Cloudflare::Email::Envelope.decode(request.headers["X-CF-Email-Envelope"])

        # Commit trusted routing metadata before ActionMailbox's after_create_commit
        # enqueues routing. Identical MIME for To/Cc/Bcc recipients is independent.
        checksum = OpenSSL::Digest::SHA256.hexdigest("v2\0#{envelope.fetch('to')}\0".b + raw_body.b)
        ActionMailbox::InboundEmail.transaction do
          inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(raw_body, message_checksum: checksum)
          if inbound
            blob = inbound.raw_email.blob
            blob.update!(metadata: blob.metadata.merge(
              Cloudflare::Email::Envelope::METADATA_KEY => envelope.merge("version" => 2),
            ))
          end
          inbound
        end
      end

      # Override ActionMailbox::BaseController's default name inference so
      # `config.action_mailbox.ingress = :cloudflare` gates this controller.
      def ingress_name
        :cloudflare
      end

      def raw_body
        @raw_body ||= begin
          request.body.rewind if request.body.respond_to?(:rewind)
          request.body.read
        end
      end

      def secret
        @secret ||= begin
          require "cloudflare/email/credentials"
          Cloudflare::Email::Credentials.ingress_secret
        end
      end
    end
  end
end
