module Cloudflare
  module Email
    class Response
      attr_reader :raw, :status

      def initialize(raw, status: 200)
        @raw    = raw.is_a?(Hash) ? raw : {}
        @status = status
      end

      def success?
        return !!@raw["success"] if @raw.key?("success") && !@raw["success"].nil?
        @status >= 200 && @status < 300
      end

      def result
        @raw["result"].is_a?(Hash) ? @raw["result"] : {}
      end

      # Provider acceptance is not final delivery. A partial acceptance is true;
      # inspect recipient outcomes before retrying any rejected recipients.
      def accepted?
        success? && (delivered.any? || queued.any? ||
          (!message_id.to_s.strip.empty? && permanent_bounces.empty? && suppressed_recipients.empty?))
      end

      def message_id
        result["message_id"] ||
          dig_message_id(result["delivered"]) ||
          dig_message_id(result["queued"])
      end

      def delivered
        Array(result["delivered"])
      end

      def queued
        Array(result["queued"])
      end

      def permanent_bounces
        Array(result["permanent_bounces"])
      end

      def suppressed_recipients
        Array(result["suppressed_recipients"])
      end

      def errors
        Array(@raw["errors"])
      end

      def messages
        Array(@raw["messages"])
      end

      def to_h
        @raw
      end

      private

      # The API may return delivered/queued as an array of strings (email
      # addresses) or an array of hashes ({message_id:, to:}).  Handle both.
      def dig_message_id(arr)
        return nil unless arr.is_a?(Array)
        first = arr.first
        first.is_a?(Hash) ? first["message_id"] : nil
      end
    end
  end
end
