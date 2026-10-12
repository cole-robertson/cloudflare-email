require "active_record"
require "mailbox_kit/tenancy"

module MailboxKit
  module ActiveRecord
    class TenantConnectionUnavailable < ::ActiveRecord::ConnectionNotEstablished; end

    # Returned instead of a pool while no valid tenant context is selected.
    # Rails' production boot asks every model's pool for its schema reflection
    # before any tenant exists (railtie "active_record.define_attribute_methods");
    # raising there aborts that loop for every model still to come. This answers
    # only that probe, with an empty reflection, and raises for anything else.
    class UnavailablePool
      def initialize(error)
        @error = error
      end

      def schema_reflection
        ::ActiveRecord::ConnectionAdapters::SchemaReflection.new(nil)
      end

      def method_missing(*)
        raise TenantConnectionUnavailable, @error.message, cause: @error
      end

      def respond_to_missing?(*)
        false
      end
    end

    # Uses the host's abstract tenant connection owner when explicitly configured.
    class Base < Tenancy.model_base(::ActiveRecord::Base)
      self.abstract_class = true

      class << self
        def connection_pool
          if Tenancy.enabled?
            begin
              Tenancy.require_context!
            rescue ConfigurationError => error
              return UnavailablePool.new(error)
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
