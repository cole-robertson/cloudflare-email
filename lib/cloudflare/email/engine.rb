require "rails/engine"
require "cloudflare/email/dev_ingress_guard"

# Register the delivery method at engine load time (not inside an initializer)
# so the `cloudflare_settings=` accessor exists before Rails' own
# "action_mailer.set_configs" initializer applies user config.
ActiveSupport.on_load(:action_mailer) do
  require "cloudflare/email/delivery_method"
  add_delivery_method :cloudflare, Cloudflare::Email::DeliveryMethod
end

module Cloudflare
  module Email
    class Engine < ::Rails::Engine
      isolate_namespace Cloudflare::Email

      initializer "cloudflare-email.development_ingress_guard" do |app|
        app.middleware.insert_before 0, DevIngressGuard if Rails.env.development?
      end

      config.to_prepare do
        if (defined?(Cloudflare::Email::Tenancy) && Cloudflare::Email::Tenancy.enabled?) ||
            (defined?(Cloudflare::Email::Mailboxes) && Cloudflare::Email::Mailboxes.enabled?)
          require "cloudflare/email/tenant_job_context"
          Cloudflare::Email::TenantJobContext.install_framework_jobs!
        end
        if defined?(Cloudflare::Email::Mailboxes) && Cloudflare::Email::Mailboxes.enabled? && defined?(::ActionMailbox::Engine)
          require "cloudflare/email/mailboxes/inbound_retention"
          ::ActionMailbox::InboundEmail.prepend(Cloudflare::Email::Mailboxes::InboundRetention) unless
            ::ActionMailbox::InboundEmail.ancestors.include?(Cloudflare::Email::Mailboxes::InboundRetention)
        end
      end

      config.before_initialize do
        unless defined?(Cloudflare::Email::Management::Engine)
          Rails.autoloaders.main.ignore(
            File.expand_path("../../../app/controllers/cloudflare/email/management", __dir__),
          )
        end
        unless defined?(::ActionMailbox::Engine)
          Rails.autoloaders.main.ignore(
            File.expand_path("../../../app/controllers/cloudflare/email/ingress_controller.rb", __dir__),
          )
        end
      end

      initializer "cloudflare-email.routes" do |app|
        next unless defined?(::ActionMailbox::Engine)

        app.routes.append do
          post "/rails/action_mailbox/cloudflare/inbound_emails",
               to: "cloudflare/email/ingress#create",
               as: :rails_cloudflare_inbound_emails
        end
      end
    end
  end
end
