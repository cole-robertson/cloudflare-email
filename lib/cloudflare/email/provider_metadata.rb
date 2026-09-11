require "json"
require "cloudflare/email/signing"

module Cloudflare
  module Email
    # Signed assertions supplied by the forwarding integration, not proof that
    # the original sender passed SPF/DKIM/DMARC. Never read these from MIME.
    module ProviderMetadata
      METADATA_KEY = "cloudflare_email_provider_metadata".freeze
      MAX_ENCODED_BYTES = 16 * 1024
      MAX_DEPTH = 8
      SOURCE = /\A[a-z][a-z0-9_.-]{0,127}\z/

      def self.valid?(value)
        value.is_a?(Hash) && value.size == 2 && value.key?("data") && value.key?("source") &&
          value["source"].is_a?(String) && SOURCE.match?(value["source"]) &&
          value["data"].is_a?(Hash) && json_value?(value, 0)
      end

      def self.json_value?(value, depth)
        case value
        when Hash
          depth < MAX_DEPTH && value.all? { |key, item| key.is_a?(String) && utf8?(key) && json_value?(item, depth + 1) }
        when Array
          depth < MAX_DEPTH && value.all? { |item| json_value?(item, depth + 1) }
        when String then utf8?(value)
        when Integer, TrueClass, FalseClass, NilClass then true
        when Float then value.finite?
        else false
        end
      end

      def self.utf8?(value)
        value.encode(Encoding::UTF_8).valid_encoding?
      rescue EncodingError
        false
      end

      def self.encode(source:, data:)
        value = {"source" => source, "data" => data}
        raise ArgumentError, "invalid provider metadata" unless valid?(value)
        encoded = Signing.base64url_encode(JSON.generate(value))
        raise ArgumentError, "provider metadata exceeds size limit" if encoded.bytesize > MAX_ENCODED_BYTES
        encoded
      end

      def self.decode(encoded)
        return unless encoded.is_a?(String) && encoded.bytesize.between?(1, MAX_ENCODED_BYTES)
        return unless /\A[A-Za-z0-9_-]+\z/.match?(encoded)
        bytes = Signing.base64url_decode(encoded)
        return unless Signing.base64url_encode(bytes) == encoded
        text = bytes.force_encoding(Encoding::UTF_8)
        return unless text.valid_encoding?
        value = JSON.parse(text, max_nesting: MAX_DEPTH)
        value if valid?(value)
      rescue JSON::ParserError, ArgumentError
        nil
      end

      def self.for(inbound_email)
        metadata = inbound_email.raw_email.blob&.metadata&.fetch(METADATA_KEY, nil)
        return unless metadata.is_a?(Hash) && metadata["signature_version"] == 3
        value = metadata.reject { |key, _| key == "signature_version" }
        value if valid?(value)
      end

      # Stable receipt identity if JSON object members arrive in another order.
      def self.canonical(value)
        case value
        when Hash then value.keys.sort.to_h { |key| [key, canonical(value[key])] }
        when Array then value.map { |item| canonical(item) }
        else value
        end
      end
    end
  end
end
