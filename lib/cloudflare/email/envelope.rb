require "mailbox_kit/address_syntax"
require "json"
require "cloudflare/email/signing"

module Cloudflare
  module Email
    # Authenticated SMTP routing metadata, kept separate from sender-supplied MIME.
    # v2 encodes exact {"from": string, "to": string} JSON as unpadded base64url.
    module Envelope
      METADATA_KEY = "cloudflare_email_envelope".freeze
      MAX_ENCODED_BYTES = 1024
      def self.valid_address?(address, allow_empty: false)
        MailboxKit::AddressSyntax.valid_address?(address, allow_empty: allow_empty)
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

      # Only metadata written after v2/v3 verification is trusted. MIME headers
      # (including X-CF-* headers) never participate in this lookup.
      def self.for(inbound_email)
        metadata = inbound_email.raw_email.blob&.metadata&.fetch(METADATA_KEY, nil)
        return nil unless metadata.is_a?(Hash) && [2, 3].include?(metadata["version"])
        value = metadata.reject { |key, _| key == "version" }
        valid?(value) ? value : nil
      end
    end
  end
end
