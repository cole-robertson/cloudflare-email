require "rails/engine"

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

      initializer "cloudflare-email.routes" do |app|
        app.routes.append do
          post "/rails/action_mailbox/cloudflare/inbound_emails",
               to: "cloudflare/email/ingress#create",
               as: :rails_cloudflare_inbound_emails
        end
      end
    end
  end
end
