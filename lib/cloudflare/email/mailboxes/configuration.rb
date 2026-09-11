require "active_record"
require "cloudflare/email/error"

module Cloudflare
  module Email
    module Mailboxes
      class Unavailable < Cloudflare::Email::Error; end

      class << self
        def configure(directory_base: ::ActiveRecord::Base, client_resolver: nil)
          if const_defined?(:ReceivingDomain, false)
            raise ConfigurationError, "configure mailboxes before loading mailbox models"
          end
          unless directory_base.is_a?(Class) && directory_base <= ::ActiveRecord::Base
            raise ConfigurationError, "directory_base must be an ActiveRecord base class"
          end
          if client_resolver && !client_resolver.respond_to?(:call)
            raise ConfigurationError, "client_resolver must be callable"
          end
          @directory_base = directory_base
          @client_resolver = client_resolver
        end

        def directory_base = @directory_base || ::ActiveRecord::Base

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

        def enabled? = @enabled == true
        def enable! = @enabled = true

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
