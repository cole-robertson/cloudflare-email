require "json"

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
    end
  end
end
