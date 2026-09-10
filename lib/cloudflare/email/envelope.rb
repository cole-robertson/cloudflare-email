require "json"
require "cloudflare/email/signing"

module Cloudflare
  module Email
    # Authenticated SMTP routing metadata, kept separate from sender-supplied MIME.
    # v2 encodes exact {"from": string, "to": string} JSON as unpadded base64url.
    module Envelope
      METADATA_KEY = "cloudflare_email_envelope".freeze
      MAX_ENCODED_BYTES = 1024
      LOCAL_PART = /\A[A-Za-z0-9.!#$%&'*+\/=\?^_`{|}~-]+\z/
      DOMAIN_LABEL = /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/

      def self.valid_address?(address, allow_empty: false)
        return false unless address.is_a?(String) && address.ascii_only?
        return true if allow_empty && address.empty?
        return false if address.bytesize > 254
        parts = address.split("@", -1)
        return false unless parts.size == 2
        local, domain = parts
        local.bytesize <= 64 && LOCAL_PART.match?(local) &&
          !local.start_with?(".") && !local.end_with?(".") && !local.include?("..") &&
          domain.split(".", -1).all? { |label| DOMAIN_LABEL.match?(label) }
      end

      def self.valid?(value)
        value.is_a?(Hash) && value.size == 2 && value.key?("from") && value.key?("to") &&
          valid_address?(value["from"], allow_empty: true) && valid_address?(value["to"])
      end

      def self.encode(from:, to:)
        value = { "from" => from, "to" => to }
        raise ArgumentError, "invalid SMTP envelope" unless valid?(value)
        Signing.base64url_encode(JSON.generate(value))
      end

      def self.decode(encoded)
        return nil unless encoded.is_a?(String) && encoded.bytesize.between?(1, MAX_ENCODED_BYTES)
        return nil unless /\A[A-Za-z0-9_-]+\z/.match?(encoded)
        decoded = Signing.base64url_decode(encoded)
        return nil unless Signing.base64url_encode(decoded) == encoded
        value = JSON.parse(decoded)
        valid?(value) ? value : nil
      rescue JSON::ParserError, ArgumentError
        nil
      end

      # Only metadata written after v2 verification is trusted. MIME headers
      # (including X-CF-* headers) never participate in this lookup.
      def self.for(inbound_email)
        metadata = inbound_email.raw_email.blob&.metadata&.fetch(METADATA_KEY, nil)
        return nil unless metadata.is_a?(Hash) && metadata["version"] == 2
        value = metadata.reject { |key, _| key == "version" }
        valid?(value) ? value : nil
      end
    end
  end
end
