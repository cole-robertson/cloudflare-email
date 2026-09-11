require "cloudflare/email/active_record/base"

module Cloudflare
  module Email
    module ActiveRecord
      class OutboundDelivery < Base
        self.table_name = "cloudflare_email_outbound_deliveries"
        has_many :outbound_recipients, class_name: "Cloudflare::Email::ActiveRecord::OutboundRecipient", dependent: :restrict_with_exception
        has_many :outbound_reconciliations, class_name: "Cloudflare::Email::ActiveRecord::OutboundReconciliation", dependent: :restrict_with_exception
        attr_readonly :account_id, :operation_key, :from_address, :recipients_json, :mime_message, :snapshot_digest

        def recipients
          JSON.parse(recipients_json)
        end

        def response
          Response.new(JSON.parse(response_json)) if response_json
        end
      end
    end
  end
end
