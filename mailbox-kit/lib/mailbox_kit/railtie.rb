require "rails/railtie"
module MailboxKit
  class Railtie < ::Rails::Railtie
    # Rails runs this public hook again when the model is reloaded. Loading the
    # kit does not itself load ActionMailbox or replace its routing lifecycle.
    initializer "mailbox-kit.inbound_retention" do
      ActiveSupport.on_load(:action_mailbox_inbound_email) do
        require "mailbox_kit/mailboxes/inbound_retention"
        prepend MailboxKit::Mailboxes::InboundRetention unless
          ancestors.include?(MailboxKit::Mailboxes::InboundRetention)
      end
    end

    config.to_prepare do
      if (defined?(MailboxKit::Tenancy) && MailboxKit::Tenancy.enabled?) || MailboxKit::Mailboxes.respond_to?(:enabled?) && MailboxKit::Mailboxes.enabled?
        require "mailbox_kit/tenant_job_context"
        MailboxKit::TenantJobContext.install_framework_jobs!
      end
    end
  end
end
