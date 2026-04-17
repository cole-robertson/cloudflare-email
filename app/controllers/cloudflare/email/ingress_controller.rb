require "cloudflare/email/verification"

module Cloudflare
  module Email
    # ActionMailbox ingress for Cloudflare Email Worker forwards.
    #
    # The shipped Worker template signs each forwarded message with HMAC-SHA256
    # over "{timestamp}.{raw_body}" and sends:
    #   X-CF-Email-Timestamp: <unix seconds>
    #   X-CF-Email-Signature: <hex digest>
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
              )
          when :stale
            payload[:result] = :stale
            head :request_timeout
          when :bad_signature
            payload[:result] = :bad_signature
            head :unauthorized
          when :ok
            inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(raw_body)
            payload[:result]     = :ok
            payload[:message_id] = inbound.message_id
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

      def raw_body
        @raw_body ||= begin
          request.body.rewind if request.body.respond_to?(:rewind)
          request.body.read
        end
      end

      def secret
        @secret ||= begin
          credential = nil
          if defined?(Rails) && Rails.application
            credential = Rails.application.credentials.dig(:cloudflare, :ingress_secret)
          end
          credential || ENV["CLOUDFLARE_INGRESS_SECRET"].to_s
        end
      end
    end
  end
end
