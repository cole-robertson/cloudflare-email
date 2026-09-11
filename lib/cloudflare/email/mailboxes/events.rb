require "cloudflare/email/active_record/delivery_events"
require "cloudflare/email/mailboxes/shared_event_receipt"
require "cloudflare/email/mailboxes/provider_correlation"

module Cloudflare
  module Email
    module Mailboxes
      # Queue ACK follows shared intake. Projection is separately replayable:
      # a crash between tenant commit and shared completion simply replays the
      # tenant's idempotent receipt. No distributed transaction is assumed.
      class Events
        class << self
          def record(event)
            outside_shared_transaction!
            event = DeliveryEvent.new(event.raw)
            receipt = SharedEventReceipt.create_or_find_by!(account_id: event.account_id, event_id: event.event_id) do |row|
              row.message_id = MessageId.normalize(event.message_id)
              row.recipient = normalize_recipient(event.recipient)
              row.payload_json = JSON.generate(event.raw)
              row.state = "pending"
            end
            raise ValidationError, "event ID already recorded with a different payload" unless receipt.event.raw == event.raw
            receipt
          end

          # Call after provider acceptance has committed in the tenant database.
          # Duplicate registrations are harmless; collisions remain visible and
          # deliberately prevent routing rather than selecting an arbitrary tenant.
          def register(delivery, tenant_key: Tenancy.require_context!)
            assert_context!(tenant_key)
            outside_shared_transaction!
            raise ArgumentError, "registration must follow the tenant commit" if delivery.class.connection.transaction_open?
            delivery.reload
            unless delivery.persisted? && %w[accepted partial].include?(delivery.state) && !delivery.provider_message_id.to_s.empty?
              raise ArgumentError, "expected a committed accepted delivery with a provider message ID"
            end
            unless OutboundMessage.where(tenant_key: tenant_key, outbound_delivery_id: delivery.id).exists?
              raise ArgumentError, "delivery does not belong to a mailbox in the current tenant"
            end
            delivery.outbound_recipients.map do |recipient|
              ProviderCorrelation.create_or_find_by!(account_id: delivery.account_id,
                message_id: MessageId.normalize(delivery.provider_message_id), recipient: normalize_recipient(recipient.recipient),
                tenant_key: tenant_key.to_s, outbound_delivery_id: delivery.id)
            end
          end

          def apply(receipt, &on_change)
            outside_shared_transaction!
            raise ArgumentError, "expected a persisted shared receipt" unless receipt.is_a?(SharedEventReceipt) && receipt.persisted?
            receipt.reload
            return receipt if receipt.state == "applied"

            candidates = ProviderCorrelation.where(account_id: receipt.account_id,
              message_id: receipt.message_id, recipient: receipt.recipient).limit(2).to_a
            outcome = :unmatched
            if candidates.length == 1
              correlation = candidates.first
              outcome = Tenancy.with(correlation.tenant_key) do
                project(receipt.event, correlation, &on_change)
              end
            end
            # Never overwrite another worker's completed projection.
            SharedEventReceipt.where(id: receipt.id, state: %w[pending unmatched]).update_all(
              state: outcome.to_s, applied_at: outcome == :applied ? Time.now.utc : nil, updated_at: Time.now.utc)
            receipt.reload
          end

          # A bounded page, not an unbounded find_each scan. Use the last scanned
          # ID as after_id for the next page, and restart at zero on the next pass.
          def replay(limit: 100, after_id: 0, account_id: nil, &on_change)
            raise ArgumentError, "limit must be between 1 and 1000" unless limit.is_a?(Integer) && (1..1000).cover?(limit)
            raise ArgumentError, "after_id must be nonnegative" unless after_id.is_a?(Integer) && after_id >= 0
            scope = SharedEventReceipt.where(state: %w[pending unmatched]).where("id > ?", after_id)
            scope = scope.where(account_id: account_id) if account_id
            scope.order(:id).limit(limit).to_a.each { |receipt| apply(receipt, &on_change) }
          end

          private

          def outside_shared_transaction!
            if SharedEventReceipt.connection.transaction_open?
              raise ArgumentError, "shared event processing must run outside an existing database transaction"
            end
          end

          def normalize_recipient(value)
            ActiveRecord::Outbox.normalize_recipient(value)
          end

          def assert_context!(key)
            raise ConfigurationError, "delivery belongs to another tenant" unless Tenancy.require_context! == key
          end

          def project(event, correlation, &on_change)
            assert_context!(correlation.tenant_key)
            return :unmatched unless OutboundMessage.where(tenant_key: correlation.tenant_key,
              outbound_delivery_id: correlation.outbound_delivery_id).exists?
            delivery = ActiveRecord::OutboundDelivery.find_by(id: correlation.outbound_delivery_id,
              account_id: event.account_id, provider_message_id: MessageId.normalize(event.message_id), state: %w[accepted partial])
            return :unmatched unless delivery && delivery.outbound_recipients.exists?(recipient: normalize_recipient(event.recipient))
            return :unmatched unless ReceivingDomain.active.where(tenant_key: correlation.tenant_key,
              account_id: event.account_id, domain: delivery.from_address.rpartition("@").last.downcase).exists?
            # DeliveryEvents also refuses collisions within the tenant. Its
            # transactional receipt protects callback writes against redelivery.
            receipt = ActiveRecord::DeliveryEvents.record(event, &on_change)
            receipt.state == "applied" ? :applied : :unmatched
          end
        end
      end
    end
  end
end
