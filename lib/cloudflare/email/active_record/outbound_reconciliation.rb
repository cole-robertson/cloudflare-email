module Cloudflare
  module Email
    module ActiveRecord
      class OutboundReconciliation < ::ActiveRecord::Base
        self.table_name = "cloudflare_email_outbound_reconciliations"
        belongs_to :outbound_delivery, class_name: "Cloudflare::Email::ActiveRecord::OutboundDelivery"
        def readonly?
          persisted?
        end
      end
    end
  end
end
