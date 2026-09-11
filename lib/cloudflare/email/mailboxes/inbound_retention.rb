module Cloudflare
  module Email
    module Mailboxes
      # ActionMailbox normally deletes processed mail after its retention window.
      # A mailbox membership owns the raw source until explicit application purge.
      module InboundRetention
        def incinerate
          return if Mailboxes.enabled? && Message.where(inbound_email_id: id).exists?
          super
        end
      end
    end
  end
end
