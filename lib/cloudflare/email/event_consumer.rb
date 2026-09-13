require "base64"
require "cloudflare/email/client"
require "cloudflare/email/delivery_event"

module Cloudflare
  module Email
    # Short-poll a dedicated Email Sending event queue from Ruby/Rails.
    # Each message is acknowledged only after the caller's block succeeds.
    # Handler/parse/ack failures propagate; unacknowledged leases expire and
    # are redelivered according to the queue's retry/dead-letter policy.
    class EventConsumer < Client
      # Up to 100 queue messages, including encoded payloads and metadata.
      DEFAULT_MAX_RESPONSE_BYTES = 32 * 1_048_576

      def initialize(queue_id:, domains: nil, max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES, **options)
        raise ConfigurationError, "queue_id is required" unless queue_id.to_s.match?(/\A[a-zA-Z0-9_-]+\z/)
        super(**options.merge(retries: 0, retry_ambiguous: false, max_response_bytes: max_response_bytes))
        @queue_id = queue_id
        @domains = domains && Array(domains).map(&:downcase)
      end

      def poll(batch_size: 5, visibility_timeout_ms: 300_000)
        raise ArgumentError, "a delivery event handler block is required" unless block_given?
        unless batch_size.is_a?(Integer) && (1..100).cover?(batch_size)
          raise ArgumentError, "batch_size must be between 1 and 100"
        end
        unless visibility_timeout_ms.is_a?(Integer) && (1_000..43_200_000).cover?(visibility_timeout_ms)
          raise ArgumentError, "visibility_timeout_ms must be between 1000 and 43200000"
        end

        response = request(:post, queue_path("pull"), {
          batch_size: batch_size, visibility_timeout_ms: visibility_timeout_ms,
        })
        messages = response.result["messages"]
        raise Error, "invalid queue pull response: messages must be an array" unless messages.is_a?(Array)

        messages.each do |message|
          unless message.is_a?(Hash) && message["lease_id"].is_a?(String) && !message["lease_id"].empty?
            raise ValidationError, "queue message is missing its lease_id"
          end
          event = decode_event(message)
          unless event.account_id == account_id && (!@domains || @domains.include?(event.domain.to_s.downcase))
            raise ValidationError, "Email Sending event does not match configured account/domain"
          end
          instrument("cloudflare_email.delivery_event", event_id: event.event_id,
                     message_id: event.message_id, status: event.status) do
            yield event
          end
          ack = request(:post, queue_path("ack"), { acks: [{ lease_id: message["lease_id"] }], retries: [] })
          unless ack.result["ackCount"] == 1
            raise Error.new("queue did not acknowledge the message; it may be redelivered", response: ack.raw, status: ack.status)
          end
        end
        messages.length
      end

      private

      def response_byte_limit(uri)
        # ACKs contain counts, never a queue batch. Keep their smaller budget
        # even when a pull needs room for 100 encoded event payloads.
        uri.path.end_with?("/messages/ack") ? [@max_response_bytes, Client::DEFAULT_MAX_RESPONSE_BYTES].min : @max_response_bytes
      end

      def queue_path(action)
        "/accounts/#{account_id}/queues/#{@queue_id}/messages/#{action}"
      end

      def decode_event(message)
        body = message["body"]
        metadata = message["metadata"]
        content_type = metadata.is_a?(Hash) ? metadata["CF-Content-Type"] : nil
        case content_type
        when "json"
          # Email Sending subscriptions return plain JSON strings from HTTP
          # pull. Also accept the base64 JSON transport used by other producers.
          begin
            body = JSON.parse(body)
          rescue JSON::ParserError
            body = JSON.parse(Base64.strict_decode64(body))
          end
        when "bytes"
          body = JSON.parse(Base64.strict_decode64(body))
        when "text"
          body = JSON.parse(body)
        else
          raise ValidationError, "unsupported queue content type; use json, bytes, or text"
        end
        DeliveryEvent.new(body)
      rescue JSON::ParserError, ArgumentError, TypeError
        raise ValidationError, "queue body must contain a valid JSON Email Sending event", cause: nil
      end
    end
  end
end
