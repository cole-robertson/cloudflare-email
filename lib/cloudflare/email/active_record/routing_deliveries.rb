# frozen_string_literal: true

require "cloudflare/email/routing_analytics"
require "cloudflare/email/active_record/outbox"

module Cloudflare
  module Email
    module ActiveRecord
      class RoutingDeliveryReceipt < Base
        self.table_name = "cloudflare_email_routing_delivery_receipts"
        belongs_to :outbound_delivery, class_name: "Cloudflare::Email::ActiveRecord::OutboundDelivery"
        encrypts :payload_json
        attr_readonly :account_id, :zone_id, :event_key, :outbound_delivery_id, :payload_json, :received_at

        def evidence
          RoutingAnalytics::Evidence.new(JSON.parse(payload_json))
        rescue JSON::ParserError, TypeError
          raise RoutingAnalytics::Error, "Stored Routing analytics evidence is malformed", cause: nil
        end
      end

      # An opt-in delivery projection, separate from Sending webhook receipts and
      # acceptance reconciliation. No method here can send or authorize a resend.
      class RoutingDeliveries
        class InvalidEvidence < RoutingAnalytics::Error; end
        ReplayResult = Struct.new(:after_id, :processed, :errors, :finished, keyword_init: true)

        class << self
          def record(delivery:, evidence:)
            unless evidence.is_a?(RoutingAnalytics::Evidence) && delivery.is_a?(OutboundDelivery) && delivery.persisted?
              raise ArgumentError, "A persisted outbound delivery and RoutingAnalytics::Evidence are required"
            end
            if RoutingDeliveryReceipt.connection.transaction_open?
              raise ArgumentError, "record must commit outside an existing transaction before projection"
            end
            validate!(delivery.reload, evidence)
            receipt = RoutingDeliveryReceipt.create_or_find_by!(account_id: evidence.account_id, event_key: evidence.identity) do |row|
              row.outbound_delivery = delivery
              row.zone_id = evidence.zone_id
              row.payload_json = JSON.generate(evidence.payload)
              row.received_at = Time.now.utc
            end
            unless receipt.outbound_delivery_id == delivery.id && receipt.evidence.same_event?(evidence)
              raise InvalidEvidence, "Routing analytics evidence identity conflict"
            end
            receipt
          end

          # Returns :applied (including idempotent replay). An existing terminal
          # fact is preserved; inspect recipient.state instead of assuming delivery.
          # Only new recipient changes invoke the same-database callback.
          def apply(receipt)
            unless receipt.is_a?(RoutingDeliveryReceipt) && receipt.persisted?
              raise ArgumentError, "A persisted RoutingDeliveryReceipt is required"
            end
            completed = false
            receipt.with_lock(requires_new: true) do
              if receipt.state == "applied"
                completed = true
                next
              end
              evidence = receipt.evidence
              unless receipt.account_id == evidence.account_id && receipt.zone_id == evidence.zone_id && receipt.event_key == evidence.identity
                raise InvalidEvidence, "Routing analytics receipt identity mismatch"
              end
              delivery = receipt.outbound_delivery
              delivery.with_lock do
                recipient = validate!(delivery, evidence)
                unless recipient.terminal?
                  recipient.update!(state: "delivered", occurred_at: evidence.occurred_at, terminal: true)
                  yield delivery, recipient if block_given?
                end
                receipt.update!(state: "applied", applied_at: Time.now.utc)
                completed = true
              end
              # ActiveRecord::Rollback can be swallowed by the nested lock's
              # transaction. Fail before this outer transaction can commit.
              raise ArgumentError, "Projection rolled back instead of completing" unless completed
            end
            raise ArgumentError, "Projection rolled back instead of completing" unless completed
            :applied
          end

          # Each failed receipt advances the cursor too. Persist after_id in the
          # host job and reset it to zero after finished; discovery gets its own budget.
          def replay(account_id:, limit: 100, after_id: 0, &on_change)
            unless account_id.is_a?(String) && !account_id.empty? && limit.is_a?(Integer) && (1..1000).cover?(limit) &&
                after_id.is_a?(Integer) && after_id >= 0
              raise ArgumentError, "An account, limit of 1..1000 and nonnegative cursor are required"
            end
            scope = RoutingDeliveryReceipt.where(account_id: account_id, state: "pending").where("id > ?", after_id).order(:id)
            rows = scope.limit(limit).to_a
            errors = []
            rows.each do |receipt|
              apply(receipt, &on_change)
            rescue StandardError => error
              errors << {receipt_id: receipt.id, error: error}
            end
            cursor = rows.last&.id || after_id
            ReplayResult.new(after_id: cursor, processed: rows.length, errors: errors,
              finished: !RoutingDeliveryReceipt.where(account_id: account_id, state: "pending").where("id > ?", cursor).exists?)
          end

          private

          def validate!(delivery, evidence)
            ids = OutboundDelivery.where(account_id: evidence.account_id,
              provider_message_id: [evidence.message_id, "<#{evidence.message_id}>"]).limit(2).pluck(:id)
            unless delivery.state == "accepted" && delivery.account_id == evidence.account_id && ids == [delivery.id] &&
                MessageId.normalize(delivery.provider_message_id) == evidence.message_id &&
                delivery.from_address.casecmp?(evidence.event.fetch("from")) && delivery.request_started_at &&
                evidence.occurred_at >= Time.at(delivery.request_started_at.to_i).utc
              raise InvalidEvidence, "Routing analytics requires one matching accepted outbound operation"
            end
            recipients = delivery.outbound_recipients.to_a
            envelope = delivery.recipients
            unless envelope.is_a?(Array) && envelope.one? && recipients.one? &&
                recipients.first.recipient == Outbox.normalize_recipient(envelope.first) &&
                recipients.first.acceptance_state == "accepted"
              raise InvalidEvidence, "Routing analytics requires one accepted saved envelope recipient"
            end
            recipients.first
          end
        end
      end
    end
  end
end
