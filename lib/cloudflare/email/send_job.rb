require "active_job"
require "cloudflare/email/active_record"

module Cloudflare
  module Email
    # Serialize only the durable operation identity, never MIME or credentials.
    # The application's job backend controls scheduling/retries; uncertainty is
    # never cleared by retrying this job.
    class SendJob < ::ActiveJob::Base
      queue_as :mailers

      def perform(account_id, operation_key)
        delivery = ActiveRecord::OutboundDelivery.find_by!(account_id: account_id, operation_key: operation_key)
        options = settings&.outbox_client_options || {}
        client = Client.new(**options.to_h.merge(account_id: Credentials.account_id,
          api_token: Credentials.api_token, retry_ambiguous: false))
        ActiveRecord::Outbox.deliver(delivery, client: client)
        handler = settings&.outbox_delivery_handler
        # This is product projection after the durable send result. If it fails,
        # a retry sees the existing accepted operation and cannot send it again.
        delivery.with_lock { handler.call(delivery) } if handler.respond_to?(:call)
        recipient_handler = settings&.outbox_recipient_handler
        if %w[accepted partial].include?(delivery.state) && delivery.provider_message_id
          ActiveRecord::DeliveryEvents.replay(account_id: account_id,
            message_id: delivery.provider_message_id,
            &(recipient_handler.method(:call) if recipient_handler.respond_to?(:call)))
        end
        if delivery.state == "unknown"
          raise ActiveRecord::Outbox::InvalidTransition, "delivery outcome is unknown; reconcile before retrying"
        end
        delivery
      end

      private

      def settings
        Rails.application.config.x.cloudflare_email if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
      end
    end
  end
end
