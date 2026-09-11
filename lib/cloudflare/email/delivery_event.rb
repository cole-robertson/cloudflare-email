require "json"
require "time"

module Cloudflare
  module Email
    # An outbound Email Sending event, delivered through Cloudflare Queues.
    # Treat event_id as an idempotency key; events may arrive more than once
    # or out of order. This is distinct from inbound ActionMailbox messages.
    class DeliveryEvent
      TYPES = %w[delivered deferred bounced failed rejected complained].freeze
      attr_reader :raw

      def initialize(raw)
        @raw = raw
        unless raw.is_a?(Hash) && raw["type"].is_a?(String) &&
               raw["type"].match?(/\Acf\.email\.sending\.message\.[a-z][a-z0-9_]*\z/) &&
               raw["payload"].is_a?(Hash) && raw["source"].is_a?(Hash) &&
               raw["source"]["type"] == "email.sending" && raw["metadata"].is_a?(Hash) &&
               raw["metadata"]["eventSchemaVersion"] == 1 &&
               [event_id, message_id, account_id, domain].all? { |value| value.is_a?(String) && !value.empty? }
          raise ValidationError, "invalid Email Sending event or unsupported schema version"
        end
      end

      def type = raw["type"]
      def status = type.delete_prefix("cf.email.sending.message.")
      def known? = TYPES.include?(status)
      def payload = raw["payload"]
      def event_id = payload["eventId"]
      def message_id = payload["messageId"]
      def recipient = payload["recipient"]
      def sender = payload["sender"]
      def terminal? = payload["terminal"] == true
      def domain = raw["source"]["domain"]
      def account_id = raw["metadata"]["accountId"]
      def occurred_at = raw["metadata"]["eventTimestamp"]
      def delivery = payload["delivery"] || {}
      def bounce = payload["bounce"] || {}
      def complaint = payload["complaint"] || {}
      def rejection = payload["rejection"] || {}
      def failure = payload["failure"] || {}

      # Use only after matching account, provider message ID, and recipient.
      # Equal timestamps keep the existing state; unknown future types remain
      # available in receipts but must not replace a recognized delivery state.
      def supersedes?(occurred_at:, terminal:)
        return false unless known?
        return false if terminal && !terminal?

        incoming = Time.iso8601(self.occurred_at.to_s)
        previous = occurred_at.is_a?(Time) ? occurred_at : Time.iso8601(occurred_at.to_s) unless occurred_at.nil?
        previous.nil? || incoming > previous
      end
    end
  end
end
