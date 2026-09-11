require "active_job"

module Cloudflare
  module Email
    module Mailboxes
      class SendJob < ::ActiveJob::Base
        queue_as :mailers

        def perform(tenant_key, mailbox_id, operation_key)
          Mailboxes.for_tenant(tenant_key) { |session| session.deliver(mailbox_id, operation_key: operation_key) }
        end
      end

      class RecoverJob < ::ActiveJob::Base
        queue_as :mailers

        def perform(tenant_key, after_id = 0)
          cursor = Mailboxes.for_tenant(tenant_key) { |session| session.recover(after_id: after_id) }
          self.class.perform_later(tenant_key, cursor) if cursor
        end
      end

      class ReplayEventsJob < ::ActiveJob::Base
        queue_as :mailers

        def perform(after_id = 0)
          handler = Mailboxes.recipient_handler
          page = Events.replay(after_id: after_id, &(handler.method(:call) if handler.respond_to?(:call)))
          self.class.perform_later(page.last.id) if page.length == 100
        end
      end
    end
  end
end
