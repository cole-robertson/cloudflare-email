module MailboxKit
    module Mailboxes
      # ActionMailbox normally deletes processed mail after its retention window.
      # A mailbox membership owns the raw source until explicit application purge.
      module InboundRetention
        def incinerate
          return super unless Mailboxes.enabled?
          # Attachment and purge use the same Rails row lock. A cleanup job
          # must not delete raw mail between the membership check and insert.
          with_lock do
            super unless Message.where(inbound_email_id: id).exists?
          end
        end
      end
    end
  end
