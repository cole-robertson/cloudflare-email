require "active_record"
require "cloudflare/email/tenancy"

module Cloudflare
  module Email
    module ActiveRecord
      # Rails may inspect every model's pool while preloading schema metadata
      # before any request has selected a tenant. Report an unavailable
      # connection using Rails' error hierarchy so boot can recover, while
      # retaining the same fail-closed guard for every caller.
      class TenantConnectionUnavailable < ::ActiveRecord::ConnectionNotEstablished; end

      # Uses the host's abstract tenant connection owner when explicitly configured.
      class Base < Tenancy.model_base(::ActiveRecord::Base)
        self.abstract_class = true

        class << self
          def connection_pool
            if Tenancy.enabled?
              begin
                Tenancy.require_context!
              rescue ConfigurationError => error
                raise TenantConnectionUnavailable, error.message
              end
            end
            super
          end
        end

        before_validation :verify_cloudflare_email_tenant!
        before_save :verify_cloudflare_email_tenant!
        before_destroy :verify_cloudflare_email_tenant!

        # These methods can bypass callbacks or load a different row with the same ID.
        %i[reload update_columns delete touch increment! decrement! association].each do |method_name|
          define_method(method_name) do |*args, **kwargs, &block|
            verify_cloudflare_email_tenant!
            super(*args, **kwargs, &block)
          end
        end

        private

        # Both new construction and persisted-row instantiation call this before
        # assigning inverse associations (which precede after_initialize).
        def init_internals
          super
          @cloudflare_email_tenant_key = Tenancy.require_context! if Tenancy.enabled?
        end

        def verify_cloudflare_email_tenant!
          return unless Tenancy.enabled?
          unless @cloudflare_email_tenant_key == Tenancy.require_context!
            raise ConfigurationError, "record belongs to a different tenant context"
          end
        end
      end
    end
  end
end
