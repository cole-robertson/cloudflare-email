require "active_job"
require "cloudflare/email/active_record"

module Cloudflare
  module Email
    class ReplayEventsJob < ::ActiveJob::Base
      queue_as :mailers

      def perform(account_id, message_id = nil)
        handler = if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
          Rails.application.config.x.cloudflare_email.outbox_recipient_handler
        end
        ActiveRecord::DeliveryEvents.replay(account_id: account_id, message_id: message_id,
          &(handler.method(:call) if handler.respond_to?(:call)))
      end
    end
  end
end
