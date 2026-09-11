require "cloudflare/email/error"

module Cloudflare
  module Email
    # An adapter boundary: the host owns tenant discovery and connection switching.
    # Configure once, before requiring any optional Active Record models.
    module Tenancy
      CONTEXT_KEY = :cloudflare_email_tenant_key

      class << self
        def configure(base_class:, switch:, current:)
          raise ConfigurationError, "configure tenancy before loading Cloudflare Email models" if @models_loaded
          raise ConfigurationError, "tenancy is already configured" if enabled?
          unless base_class.is_a?(Class) && base_class.respond_to?(:abstract_class?) && base_class.abstract_class?
            raise ConfigurationError, "base_class must be an abstract Active Record class"
          end
          unless switch.respond_to?(:call) && current.respond_to?(:call)
            raise ConfigurationError, "switch and current must be callable"
          end

          @base_class, @switch, @current = base_class, switch, current
          self
        end

        def enabled?
          !@switch.nil?
        end

        def model_base(default)
          @models_loaded = true
          @base_class || default
        end

        def current_key
          Thread.current[CONTEXT_KEY]
        end

        # Only trusted host integration code should use this to capture new work.
        # Model access and persisted job deserialization still require explicit
        # gem context; the adapter must not invent a default tenant here.
        def host_current_key
          return unless enabled?
          key = @current.call
          normalize_key(key) unless key.nil?
        end

        def normalize_key(key)
          unless key.is_a?(String) && !key.empty? && key == key.strip && !key.match?(/[[:cntrl:]]/)
            raise ConfigurationError, "tenant key must be a nonempty string without surrounding whitespace or control characters"
          end
          key.dup.freeze
        end

        def require_context!
          key = current_key
          raise ConfigurationError, "an explicit Cloudflare Email tenant context is required" unless key
          if enabled? && @current.call != key
            raise ConfigurationError, "host database tenant does not match Cloudflare Email tenant context"
          end
          key
        end

        def with(key)
          key = normalize_key(key)
          previous = current_key
          run = proc do
            Thread.current[CONTEXT_KEY] = key
            require_context!
            yield
          ensure
            Thread.current[CONTEXT_KEY] = previous
          end
          enabled? ? @switch.call(key, &run) : run.call
        end
      end
    end
  end
end
