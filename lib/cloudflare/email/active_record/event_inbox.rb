require "active_record"
require "cloudflare/email/error"
require "cloudflare/email/delivery_event"
require "cloudflare/email/message_id"
require "cloudflare/email/active_record/event_receipt"

module Cloudflare
  module Email
    module ActiveRecord
      # Optional durable boundary between queue acknowledgment and application work.
      # Keep handler database writes on EventReceipt's connection; external effects
      # cannot be rolled back and should use an application outbox.
      class EventInbox
        class << self
          # Use directly in EventConsumer#poll. A returned receipt has committed,
          # so the queue can ACK even when its message has not been matched yet.
          def record(event)
            if EventReceipt.connection.transaction_open?
              raise ArgumentError, "record must run outside an existing database transaction before queue acknowledgment"
            end

            event = DeliveryEvent.new(event.raw)
            receipt = EventReceipt.create_or_find_by!(account_id: event.account_id, event_id: event.event_id) do |row|
              row.message_id = MessageId.normalize(event.message_id)
              row.payload_json = JSON.generate(event.raw)
              row.state = "pending"
            end
            unless receipt.event.raw == event.raw
              raise ValidationError, "event ID already recorded with a different payload"
            end
            receipt
          end

          # The handler must explicitly return :applied or :unmatched. Exceptions
          # roll back both its database writes and the receipt transition.
          def apply(receipt)
            raise ArgumentError, "an event handler block is required" unless block_given?
            raise ArgumentError, "expected a persisted EventReceipt" unless receipt.is_a?(EventReceipt) && receipt.persisted?

            completed = false
            receipt.with_lock(requires_new: true) do
              if receipt.state == "applied"
                completed = true
                next
              end
              outcome = yield receipt.event
              unless [:applied, :unmatched].include?(outcome)
                raise ArgumentError, "event handler must return :applied or :unmatched"
              end
              receipt.update!(state: outcome.to_s, applied_at: outcome == :applied ? Time.now.utc : nil)
              completed = true
            end
            raise ArgumentError, "event handler rolled back instead of returning an outcome" unless completed
            receipt
          end

          # Replay pending/unmatched receipts after correlating provider IDs, or
          # from a recurring job. Ordering policy belongs to the application.
          def replay(account_id: nil, message_id: nil, batch_size: 100, &handler)
            raise ArgumentError, "an event handler block is required" unless handler
            raise ArgumentError, "batch_size must be positive" unless batch_size.is_a?(Integer) && batch_size.positive?

            scope = EventReceipt.where(state: ["pending", "unmatched"])
            scope = scope.where(account_id: account_id) if account_id
            scope = scope.where(message_id: MessageId.normalize(message_id)) if message_id
            count = 0
            scope.find_each(batch_size: batch_size) do |receipt|
              apply(receipt, &handler)
              count += 1
            end
            count
          end
        end
      end
    end
  end
end
