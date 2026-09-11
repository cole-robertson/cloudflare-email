require "cloudflare/email/tenancy"

module Cloudflare
  module Email
    # Opt in with `prepend Cloudflare::Email::TenantJobContext` on jobs whose
    # arguments or work reference tenant records. Queue payloads must be trusted.
    module TenantJobContext
      PAYLOAD_KEY = "cloudflare_email_tenant_key".freeze

      def serialize
        key = cloudflare_email_job_tenant_key
        return super unless key
        Tenancy.with(key) do
          payload = super
          verify_cloudflare_email_host_tenant!(key, payload["tenant"])
          payload.merge(PAYLOAD_KEY => key)
        end
      end

      def deserialize(job_data)
        # Bind before super: host job integrations may deserialize model arguments
        # eagerly. Never infer a missing tenant from the worker's ambient context.
        if !job_data.key?(PAYLOAD_KEY) && cloudflare_email_optional_job_context?
          @cloudflare_email_job_tenant_key = nil
          return super
        end
        @cloudflare_email_job_tenant_key = Tenancy.normalize_key(job_data[PAYLOAD_KEY])
        verify_cloudflare_email_host_tenant!(@cloudflare_email_job_tenant_key, job_data["tenant"])
        Tenancy.with(@cloudflare_email_job_tenant_key) { super }
      end

      def perform_now
        # Active Job resolves GlobalIDs before around_perform, so that callback
        # cannot safely implement database tenant selection.
        key = cloudflare_email_job_tenant_key
        return super unless key
        if defined?(::ActiveRecord::Tenanted::Job) && respond_to?(:tenant)
          verify_cloudflare_email_host_tenant!(key, tenant)
        end
        Tenancy.with(key) { super }
      end

      def self.install_framework_jobs!
        if defined?(::ActionMailbox)
          %i[RoutingJob IncinerationJob].each do |name|
            next unless ::ActionMailbox.const_defined?(name)
            klass = ::ActionMailbox.const_get(name)
            klass.define_singleton_method(:cloudflare_email_optional_job_context?) { !Tenancy.enabled? }
            klass.prepend(self) unless klass.ancestors.include?(self)
          end
        end
        if defined?(::ActiveStorage)
          %i[BaseJob AnalyzeJob PurgeJob MirrorJob TransformJob PreviewImageJob].each do |name|
            next unless ::ActiveStorage.const_defined?(name)
            klass = ::ActiveStorage.const_get(name)
            klass.define_singleton_method(:cloudflare_email_optional_job_context?) { !Tenancy.enabled? }
            klass.prepend(self) unless klass.ancestors.include?(self)
          end
        end
      end

      private

      def cloudflare_email_job_tenant_key
        # Once serialized/deserialized, retries retain their original tenant even
        # if re-enqueued from a different tenant or outside a tenant context.
        return @cloudflare_email_job_tenant_key if instance_variable_defined?(:@cloudflare_email_job_tenant_key)
        return nil if cloudflare_email_optional_job_context? && !Tenancy.current_key
        # Native uploads/mailbox work may originate in the host's own with_tenant
        # block. Framework jobs can capture that trusted context on first use.
        # deserialize never takes this path for missing persisted metadata.
        if !Tenancy.current_key && self.class.respond_to?(:cloudflare_email_optional_job_context?)
          key = Tenancy.host_current_key
          return @cloudflare_email_job_tenant_key = key if key
        end
        @cloudflare_email_job_tenant_key = Tenancy.require_context!
      end

      def cloudflare_email_optional_job_context?
        self.class.respond_to?(:cloudflare_email_optional_job_context?) && self.class.cloudflare_email_optional_job_context?
      end

      def verify_cloudflare_email_host_tenant!(key, host_key)
        if host_key && host_key != key
          raise ConfigurationError, "job host tenant conflicts with Cloudflare Email tenant context"
        end
      end
    end
  end
end
