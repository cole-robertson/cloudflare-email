module Cloudflare
  module Email
    module ActiveRecord
      class EventReceipt < ::ActiveRecord::Base
        self.table_name = "cloudflare_email_event_receipts"
        attr_readonly :account_id, :event_id, :message_id, :payload_json

        # JSON text avoids a dependency on database-specific JSON column types.
        def event
          DeliveryEvent.new(JSON.parse(payload_json))
        end
      end
    end
  end
end
