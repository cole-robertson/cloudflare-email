require "cloudflare/email/active_record/base"

module Cloudflare
  module Email
    module ActiveRecord
      class OutboundRecipient < Base
        self.table_name = "cloudflare_email_outbound_recipients"
        belongs_to :outbound_delivery, class_name: "Cloudflare::Email::ActiveRecord::OutboundDelivery"
        attr_readonly :outbound_delivery_id, :recipient
      end
    end
  end
end
