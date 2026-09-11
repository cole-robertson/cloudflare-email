require "cloudflare/email/ingress"

module Cloudflare
  module Email
    # ActionMailbox ingress for Cloudflare Email Worker forwards.
    #
    # The default Worker uses v2 authenticated SMTP envelopes; custom Workers
    # can opt into v3 to authenticate additional provider metadata. Both use
    # the shared, bounded Ingress verifier before any tenant lookup or storage.
    #
    # Set the shared secret in Rails credentials under cloudflare.ingress_secret
    # (or in the CLOUDFLARE_INGRESS_SECRET env var) and as the Worker secret
    # INGRESS_SECRET via `wrangler secret put INGRESS_SECRET`.
    class IngressController < ActionMailbox::BaseController
      DEFAULT_MAX_EMAIL_BYTES = 25 * 1024 * 1024
      param_encoding :create, "raw_email", Encoding::ASCII_8BIT

      def create
        ActiveSupport::Notifications.instrument(
          "cloudflare_email.ingress",
          bytes: 0,
        ) do |payload|
          request.body.rewind if request.body.respond_to?(:rewind)
          result = Cloudflare::Email::Ingress.verify(secret: secret,
            headers: request.headers, body: request.body,
            content_length: request.content_length, max_email_bytes: max_email_bytes)
          payload[:bytes] = result.bytes.to_i
          payload[:result] = result.status
          case result.status
          when :stale
            head :request_timeout
          when :bad_signature
            head :unauthorized
          when :too_large
            head :payload_too_large
          when :ok
            inbound = if defined?(Cloudflare::Email::Mailboxes) && Cloudflare::Email::Mailboxes.enabled?
              recipient = result.message.envelope.fetch("to")
              begin
                Cloudflare::Email::Mailboxes.receive(recipient: recipient) { result.message.persist_action_mailbox! }
              rescue Cloudflare::Email::Mailboxes::Unavailable
                payload[:result] = :unavailable_mailbox
                next head(:unprocessable_entity)
              end
            else
              result.message.persist_action_mailbox!
            end
            payload[:result]     = inbound ? :ok : :duplicate
            payload[:message_id] = inbound&.message_id
            head :ok
          end
        end
      end

      private

      # Override ActionMailbox::BaseController's default name inference so
      # `config.action_mailbox.ingress = :cloudflare` gates this controller.
      def ingress_name
        :cloudflare
      end

      def max_email_bytes
        @max_email_bytes ||= begin
          value = Integer(ENV.fetch("MAX_EMAIL_BYTES", DEFAULT_MAX_EMAIL_BYTES.to_s), 10)
          raise ArgumentError, "MAX_EMAIL_BYTES must be positive" unless value.positive?
          value
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
