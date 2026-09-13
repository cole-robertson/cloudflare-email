require "rails/railtie"
module MailboxKit
  class Railtie < ::Rails::Railtie
    config.to_prepare do
      if (defined?(MailboxKit::Tenancy) && MailboxKit::Tenancy.enabled?) || MailboxKit::Mailboxes.respond_to?(:enabled?) && MailboxKit::Mailboxes.enabled?
        require "mailbox_kit/tenant_job_context"
        MailboxKit::TenantJobContext.install_framework_jobs!
      end
      if MailboxKit::Mailboxes.respond_to?(:enabled?) && MailboxKit::Mailboxes.enabled? && defined?(::ActionMailbox::Engine)
        require "mailbox_kit/mailboxes/inbound_retention"
        ::ActionMailbox::InboundEmail.prepend(MailboxKit::Mailboxes::InboundRetention) unless
          ::ActionMailbox::InboundEmail.ancestors.include?(MailboxKit::Mailboxes::InboundRetention)
      end
    end
  end
end
