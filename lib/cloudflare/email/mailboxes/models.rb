require "cloudflare/email/active_record/base"
require "mailbox_kit/mailboxes/configuration"
require "mailbox_kit/mailboxes/models"
module Cloudflare
  module Email
    module Mailboxes
      Mailbox.has_many :outbound_messages, class_name: "MailboxKit::Mailboxes::OutboundMessage"
      # A process may also serve core-only tenants without the outbound schema.
      Mailbox.before_destroy do
        if self.class.connection.data_source_exists?(OutboundMessage.table_name) && outbound_messages.exists?
          raise ::ActiveRecord::DeleteRestrictionError, :outbound_messages
        end
      end
      class OutboundMessage < Cloudflare::Email::ActiveRecord::Base
        include TenantIdentity
        self.table_name = "cloudflare_email_mailbox_outbound_messages"
        belongs_to :mailbox, class_name: "MailboxKit::Mailboxes::Mailbox"
        belongs_to :outbound_delivery, class_name: "Cloudflare::Email::ActiveRecord::OutboundDelivery"
        attr_readonly :mailbox_id, :outbound_delivery_id
        validates :mailbox, :outbound_delivery, presence: true
        # Enforce uniqueness in the database so idempotent link creation works.
        validate { validate_parent_tenant(mailbox, :mailbox) }
      end
    end
  end
end
