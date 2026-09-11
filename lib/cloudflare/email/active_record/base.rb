require "active_record"
require "cloudflare/email/tenancy"

module Cloudflare
  module Email
    module ActiveRecord
      # Uses the host's abstract tenant connection owner when explicitly configured.
      class Base < Tenancy.model_base(::ActiveRecord::Base)
        self.abstract_class = true

        class << self
          def connection_pool
            Tenancy.require_context! if Tenancy.enabled?
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
