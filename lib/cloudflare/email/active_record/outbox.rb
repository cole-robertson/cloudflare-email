require "active_record"
require "digest"
require "cloudflare-email"
require "cloudflare/email/active_record/outbound_delivery"
require "cloudflare/email/active_record/outbound_recipient"
require "cloudflare/email/active_record/outbound_reconciliation"

module Cloudflare
  module Email
    module ActiveRecord
      # Durable, single-attempt boundary. A retry job may revisit an accepted
      # operation, but uncertainty always requires an explicit operator decision.
      class Outbox
        class Error < Cloudflare::Email::Error; end
        class InvalidTransition < Error; end
        class SnapshotConflict < Error; end

        class << self
          def acceptance_state(states)
            aggregate(states)
          end

          def normalize_recipient(value)
            local, separator, domain = value.to_s.rpartition("@")
            separator.empty? ? value.to_s : "#{local}@#{domain.downcase}"
          end

          def prepare(account_id:, operation_key:, from:, recipients:, mime_message:)
            [account_id, operation_key, from].each do |value|
              raise ArgumentError, "account, operation key and sender must be nonempty strings" unless value.is_a?(String) && !value.strip.empty?
            end
            unless recipients.is_a?(Array) && recipients.any? && recipients.all? { |v| v.is_a?(String) && !v.strip.empty? }
              raise ArgumentError, "recipients must be a nonempty array of addresses"
            end
            raise ArgumentError, "mime_message must be a nonempty String" unless mime_message.is_a?(String) && !mime_message.empty?
            addresses = recipients.map { |address| normalize_recipient(address) }.uniq
            json = JSON.generate(addresses)
            digest = Digest::SHA256.hexdigest(JSON.generate([account_id, from, addresses]) + "\0" + mime_message.b)
            OutboundDelivery.transaction do
              delivery = OutboundDelivery.create_or_find_by!(account_id: account_id, operation_key: operation_key) do |row|
                row.assign_attributes(from_address: from, recipients_json: json, mime_message: mime_message.b,
                  snapshot_digest: digest, state: "prepared")
              end
              raise SnapshotConflict, "operation key already has a different immutable message" unless delivery.snapshot_digest == digest
              addresses.each { |address| delivery.outbound_recipients.create_or_find_by!(recipient: address) }
              delivery
            end
          end

          def deliver(delivery, client: nil)
            persisted!(delivery)
            outside_transaction!
            delivery.reload
            return delivery if %w[accepted partial].include?(delivery.state)
            client ||= Client.new(account_id: Credentials.account_id, api_token: Credentials.api_token)
            unless client.account_id.to_s == delivery.account_id && client.respond_to?(:retry_ambiguous) && client.retry_ambiguous == false
              raise ConfigurationError, "outbox client must match the account and disable ambiguous retries"
            end
            now = Time.now.utc
            claimed = OutboundDelivery.where(id: delivery.id, state: "prepared").update_all(state: "sending", request_started_at: now, updated_at: now)
            unless claimed == 1
              delivery.reload
              return delivery if %w[accepted partial].include?(delivery.state)
              raise InvalidTransition, "cannot send an operation in #{delivery.state}; uncertainty requires reconciliation"
            end

            # Everything after this durable claim can leave an ambiguous outcome.
            begin
              response = client.send_raw(from: delivery.from_address, recipients: delivery.recipients, mime_message: delivery.mime_message)
            rescue StandardError => error
              record_failure(delivery, error)
              raise
            end
            begin
              outcomes, provider_message_id = response_outcomes(response, delivery.recipients)
              delivery.with_lock do
                raise InvalidTransition, "send claim changed during delivery" unless delivery.state == "sending"
                outcomes.each do |address, state|
                  delivery.outbound_recipients.find_by!(recipient: address).update!(state: state, acceptance_state: state, occurred_at: nil,
                    terminal: %w[delivered bounced suppressed].include?(state))
                end
                delivery.update!(state: aggregate(outcomes.values), provider_message_id: provider_message_id,
                  response_json: JSON.generate(response.to_h), completed_at: Time.now.utc, error_class: nil)
              end
            rescue StandardError => error
              # Even a local validation/persistence error here follows provider
              # acceptance. Never convert it into permission to resend.
              mark_unknown(delivery.id, error)
              raise
            end
            delivery.reload
          end

          def reconcile(delivery, outcome:, actor:, reason:, evidence:, provider_message_id: nil, recipients: nil, confirm_sender_stopped: false)
            persisted!(delivery)
            raise ArgumentError, "outcome must be accepted or not_sent" unless %w[accepted not_sent].include?(outcome.to_s)
            [actor, reason, evidence].each do |value|
              raise ArgumentError, "actor, reason and evidence are required strings" unless value.is_a?(String) && !value.strip.empty?
            end
            provider_message_id = validated_message_id(provider_message_id)
            if outcome.to_s == "accepted" && provider_message_id.nil?
              raise ArgumentError, "accepted reconciliation requires a provider message ID"
            end
            completed = false
            delivery.with_lock(requires_new: true) do
              allowed = %w[unknown partial].include?(delivery.state) || (delivery.state == "sending" && confirm_sender_stopped == true &&
                delivery.request_started_at && delivery.request_started_at <= Time.now.utc - 900)
              raise InvalidTransition, "only uncertain operations may be reconciled; a sending process must be confirmed stopped and at least 15 minutes old" unless allowed
              rows = delivery.outbound_recipients.to_a
              unresolved = rows.select { |row| %w[unknown prepared sending].include?(row.acceptance_state) }.map(&:recipient)
              selected = recipients || unresolved
              selected = selected.map { |address| normalize_recipient(address) } if selected.is_a?(Array)
              unless selected.is_a?(Array) && selected.any? && (selected - unresolved).empty? && selected.uniq == selected
                raise ArgumentError, "recipients must be unique unresolved snapshot recipients"
              end
              existing_id = validated_message_id(delivery.provider_message_id.presence)
              if provider_message_id && existing_id && provider_message_id != existing_id
                raise ArgumentError, "provider message ID conflicts with the existing operation"
              end
              delivery.outbound_reconciliations.create!(actor: actor, reason: reason, evidence: evidence,
                outcome: outcome.to_s, provider_message_id: provider_message_id, recipients_json: JSON.generate(selected))
              states = rows.map do |recipient|
                unless selected.include?(recipient.recipient)
                  recipient.update!(state: "unknown", acceptance_state: "unknown") if %w[prepared sending].include?(recipient.acceptance_state)
                  next recipient.acceptance_state
                end
                state = outcome.to_s == "not_sent" ? "not_sent" : "accepted"
                recipient.update!(state: state, acceptance_state: state, occurred_at: nil, terminal: state == "not_sent")
                state
              end
              delivery.update!(state: states.all? { |state| state == "not_sent" } ? "confirmed_not_sent" : aggregate(states),
                provider_message_id: provider_message_id || existing_id, completed_at: Time.now.utc)
              yield delivery if block_given?
              completed = true
            end
            raise InvalidTransition, "reconciliation rolled back instead of completing" unless completed
            delivery.reload
          end

          private

          def persisted!(delivery)
            raise ArgumentError, "expected a persisted OutboundDelivery" unless delivery.is_a?(OutboundDelivery) && delivery.persisted?
          end

          def outside_transaction!
            raise ArgumentError, "outbox network delivery must run outside an existing database transaction" if OutboundDelivery.connection.transaction_open?
          end

          def record_failure(delivery, error)
            # Only an explicit provider 4xx rejection proves nonacceptance.
            rejected = error.is_a?(Cloudflare::Email::Error) && [400, 401, 403, 422, 429].include?(error.status)
            OutboundDelivery.transaction do
              count = OutboundDelivery.where(id: delivery.id, state: "sending").update_all(state: rejected ? "rejected" : "unknown",
                error_class: error.class.name, completed_at: Time.now.utc, updated_at: Time.now.utc)
              OutboundRecipient.where(outbound_delivery_id: delivery.id).update_all(state: rejected ? "rejected" : "unknown", acceptance_state: rejected ? "rejected" : "unknown") if count == 1
            end
          rescue StandardError
            # A database outage leaves the already committed sending claim.
            # It is deliberately just as non-retryable as unknown.
            nil
          end

          def mark_unknown(id, error)
            OutboundDelivery.where(id: id, state: "sending").update_all(state: "unknown", error_class: error.class.name, updated_at: Time.now.utc)
          rescue StandardError
            nil
          end

          def response_outcomes(response, addresses)
            raise ValidationError, "invalid provider response" unless response.is_a?(Response) && response.success?
            outcomes = addresses.to_h { |address| [address, "unknown"] }
            result = response.result
            ids = [validated_message_id(result["message_id"])]
            groups = { "delivered" => "delivered", "queued" => "queued", "permanent_bounces" => "bounced", "suppressed_recipients" => "suppressed" }
            seen = {}
            groups.each do |key, state|
              entries = result.fetch(key, [])
              raise ValidationError, "invalid recipient outcomes" unless entries.is_a?(Array)
              entries.each do |entry|
                ids << validated_message_id(entry["message_id"]) if entry.is_a?(Hash)
                address = entry.is_a?(Hash) ? (entry["to"] || entry["email"] || entry["recipient"] || entry["address"]) : entry
                address = normalize_recipient(address)
                raise ValidationError, "unknown or conflicting provider recipient" unless addresses.include?(address) && !seen[address]
                seen[address] = true
                outcomes[address] = state
              end
            end
            raise ValidationError, "multiple provider message IDs cannot be correlated to one operation" if ids.compact.uniq.size > 1
            if seen.empty? && ids.compact.any?
              outcomes.transform_values! { "accepted" }
            end
            [outcomes, ids.compact.first]
          end

          def validated_message_id(value)
            return nil if value.nil?
            unless value.is_a?(String)
              raise ValidationError, "provider message ID must be a nonempty string"
            end
            normalized = MessageId.normalize(value)
            if normalized.empty? || normalized.match?(/[\s<>]/)
              raise ValidationError, "provider message ID must not contain whitespace or brackets"
            end
            normalized
          end

          def aggregate(states)
            accepted = states.count { |state| %w[accepted delivered queued].include?(state) }
            return "accepted" if accepted == states.size
            return "partial" if accepted.positive?
            return "rejected" if states.all? { |state| %w[bounced suppressed rejected not_sent].include?(state) }
            "unknown"
          end
        end
      end
    end
  end
end
