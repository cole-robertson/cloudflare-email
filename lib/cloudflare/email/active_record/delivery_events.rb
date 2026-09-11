require "cloudflare/email/active_record/event_inbox"
require "cloudflare/email/active_record/outbox"
require "time"

module Cloudflare
  module Email
    module ActiveRecord
      # Durable receipt + recipient projection. Application callbacks may update
      # product records on this connection; external effects need their own outbox.
      class DeliveryEvents
        class << self
          def record(event, &on_change)
            validate!(event)
            receipt = EventInbox.record(event)
            EventInbox.apply(receipt) { |stored| project(stored, &on_change) }
          end

          def replay(account_id:, message_id: nil, batch_size: 100, &on_change)
            raise ArgumentError, "account_id is required" if account_id.to_s.empty?
            EventInbox.replay(account_id: account_id, message_id: message_id,
                              batch_size: batch_size) { |event| project(event, &on_change) }
          end

          private

          def validate!(event)
            raise ValidationError, "delivery event recipient is required" unless event.recipient.is_a?(String) && !event.recipient.strip.empty?
            Time.iso8601(event.occurred_at.to_s)
          rescue ArgumentError
            raise ValidationError, "delivery event timestamp must be ISO8601"
          end

          def project(event)
            validate!(event)
            return :unmatched unless event.known?

            # Refuse ambiguous correlation instead of picking the newest record.
            ids = OutboundDelivery.where(account_id: event.account_id,
              provider_message_id: MessageId.normalize(event.message_id),
              state: %w[accepted partial]).limit(2).pluck(:id)
            return :unmatched unless ids.length == 1

            delivery = OutboundDelivery.find(ids.first)
            outcome = :unmatched
            delivery.with_lock do
              next unless %w[accepted partial].include?(delivery.state)
              recipient = delivery.outbound_recipients.find_by(
                recipient: Outbox.normalize_recipient(event.recipient))
              next unless recipient

              if event.supersedes?(occurred_at: recipient.occurred_at, terminal: recipient.terminal?)
                attributes = { state: event.status, occurred_at: Time.iso8601(event.occurred_at), terminal: event.terminal? }
                # A correlated lifecycle event proves Cloudflare processed this
                # recipient even if its initial response omitted the outcome.
                if recipient.acceptance_state == "unknown"
                  attributes[:acceptance_state] = "accepted"
                end
                recipient.update!(attributes)
                if attributes[:acceptance_state]
                  delivery.update!(state: Outbox.acceptance_state(delivery.outbound_recipients.pluck(:acceptance_state)))
                end
                yield delivery, recipient if block_given?
              end
              outcome = :applied
            end
            outcome
          end
        end
      end
    end
  end
end
