module Cloudflare
  module Email
    module ActiveRecord
      module OutboxNotifications
        def prepare(**options)
          notify_outbox("prepare", account_id: options[:account_id], operation_key: options[:operation_key]) { super }
        end

        def deliver(delivery, **options)
          notify_outbox("send", account_id: delivery.account_id, operation_key: delivery.operation_key) { super }
        end

        def reconcile(delivery, **options, &block)
          notify_outbox("reconcile", account_id: delivery.account_id, operation_key: delivery.operation_key) { super }
        end

        private

        def notify_outbox(action, **payload)
          return yield unless defined?(::ActiveSupport::Notifications)

          ::ActiveSupport::Notifications.instrument("cloudflare_email.outbox_#{action}", payload) do |details|
            result = yield
            details[:delivery_id] = result.id
            details[:state] = result.state
            result
          end
        end
      end

      Outbox.singleton_class.prepend(OutboxNotifications)
    end
  end
end
