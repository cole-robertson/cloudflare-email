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
