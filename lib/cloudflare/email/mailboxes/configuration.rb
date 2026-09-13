require "mailbox_kit/mailboxes/configuration"
require "cloudflare/email/error"

module Cloudflare
  module Email
    Mailboxes = MailboxKit::Mailboxes unless const_defined?(:Mailboxes, false)
    module Mailboxes

      module CloudflareConfiguration
        def configure(directory_base: ::ActiveRecord::Base, client_resolver: nil)
          if client_resolver && !client_resolver.respond_to?(:call)
            raise ConfigurationError, "client_resolver must be callable"
          end
          super(directory_base: directory_base)
          @client_resolver = client_resolver
        end
      end
      singleton_class.prepend(CloudflareConfiguration)

      class << self
        def delivery_handler = rails_setting(:outbox_delivery_handler)
        def recipient_handler = rails_setting(:outbox_recipient_handler)

        def client_for(tenant_key, account_id)
          client = if @client_resolver
            @client_resolver.call(tenant_key, account_id)
          else
            require "cloudflare/email/credentials"
            unless Credentials.account_id == account_id
              raise ConfigurationError, "configure a tenant/account client_resolver for this sending account"
            end
            Client.new(account_id: account_id, api_token: Credentials.api_token, retry_ambiguous: false)
          end
          unless client.account_id == account_id && client.retry_ambiguous == false
            raise ConfigurationError, "mailbox client must match account and disable ambiguous retries"
          end
          client
        end

        private

        def rails_setting(name)
          if defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application
            ::Rails.application.config.x.cloudflare_email.public_send(name)
          end
        end
      end
    end
  end
end
