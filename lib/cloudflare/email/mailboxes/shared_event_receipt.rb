module Cloudflare
  module Email
    module Mailboxes
      class SharedEventReceipt < Mailboxes.directory_base
        self.table_name = "cloudflare_email_shared_event_receipts"
        attr_readonly :account_id, :event_id, :message_id, :recipient, :payload_json

        def event
          DeliveryEvent.new(JSON.parse(payload_json))
        end
      end
    end
  end
end
