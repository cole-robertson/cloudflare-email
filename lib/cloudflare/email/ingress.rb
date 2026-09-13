require "digest"
require "cloudflare/email/verification"

module Cloudflare
  module Email
    # Shared bounded verification for custom Rack/Rails ingestion endpoints.
    # This API deliberately performs no domain lookup or business processing.
    module Ingress
      DEFAULT_MAX_EMAIL_BYTES = 25 * 1024 * 1024
      Result = Struct.new(:status, :message, :bytes, keyword_init: true)

      class VerifiedMessage
        attr_reader :body, :envelope, :provider_metadata, :storage_metadata, :message_checksum

        def initialize(body:, envelope:, provider_metadata:, version:)
          @body = body.b.freeze
          @envelope = Ingress.deep_freeze(envelope)
          @provider_metadata = Ingress.deep_freeze(provider_metadata)
          @storage_metadata = {Envelope::METADATA_KEY => envelope.merge("version" => version.to_i)}
          if provider_metadata
            @storage_metadata[ProviderMetadata::METADATA_KEY] = provider_metadata.merge("signature_version" => 3)
          end
          Ingress.deep_freeze(@storage_metadata)
          identity = if version == "3"
            "v3\0#{JSON.generate([envelope.fetch('from'), envelope.fetch('to'), ProviderMetadata.canonical(provider_metadata)])}\0".b
          else
            "v2\0#{envelope.fetch('to')}\0".b
          end
          @message_checksum = Digest::SHA256.hexdigest(identity + @body).freeze
          freeze
        end
        private_class_method :new

        # Call within Mailboxes.receive when using the optional registry so the
        # framework records and memberships share the resolved tenant context.
        # Custom endpoints may instead persist body/metadata in their own store.
        def persist_action_mailbox!
          result = persist_rails_record
          result.record if result.created?
        end

        # Verify once, resolve the envelope recipient before storage, then use
        # the kit's ordinary Rails membership path. A duplicate can repair a
        # missing membership without scheduling Rails processing again.
        def receive_into_mailbox!
          result = nil
          Mailboxes.receive(recipient: envelope.fetch("to")) do
            result = persist_rails_record
            result.record
          end
          result.record if result.created?
        end

        private

        def persist_rails_record
          require "mailbox_kit/inbound_email"
          MailboxKit::InboundEmail.persist(source: body, message_checksum: message_checksum,
            message_id: stable_message_id, metadata: storage_metadata)
        end

        # ActionMailbox's fallback includes Socket.gethostname. A replay on a
        # different Rails host must use the same database identity, while the
        # original MIME stays untouched. Preserve parseable provider IDs.
        def stable_message_id
          parsed = begin
            ::Mail.from_source(body).message_id
          rescue StandardError
            nil
          end
          parsed || "#{message_checksum}@cloudflare-email.invalid"
        end
      end

      def self.verify(secret:, headers:, body:, content_length: nil,
        max_email_bytes: DEFAULT_MAX_EMAIL_BYTES, now: Time.now.to_i, window: Verification::DEFAULT_WINDOW)
        unless max_email_bytes.is_a?(Integer) && max_email_bytes.positive?
          raise ArgumentError, "max_email_bytes must be a positive integer"
        end
        values = %w[Timestamp Signature Signature-Version Envelope Metadata].to_h do |name|
          key = "X-CF-Email-#{name}"
          value = headers[key] || headers["HTTP_#{key.upcase.tr('-', '_')}"]
          [name, value.is_a?(String) ? value.dup.freeze : value]
        end
        options = {secret: secret, timestamp: values["Timestamp"], signature: values["Signature"],
          version: values["Signature-Version"], envelope: values["Envelope"], metadata: values["Metadata"],
          now: now, window: window}
        status = Verification.verify_headers(**options)
        return Result.new(status: status).freeze unless status == :ok
        if content_length
          length = Integer(content_length.to_s, exception: false)
          return Result.new(status: :bad_signature).freeze unless length && length >= 0
          return Result.new(status: :too_large).freeze if length > max_email_bytes
        end
        raw = if body.is_a?(String)
          return Result.new(status: :too_large).freeze if body.bytesize > max_email_bytes
          body.dup.b
        elsif body.respond_to?(:read)
          buffer = +"".b
          while buffer.bytesize <= max_email_bytes
            chunk = body.read(max_email_bytes + 1 - buffer.bytesize)
            break if chunk.nil? || chunk.empty?
            buffer << chunk.b
          end
          buffer
        else
          raise ArgumentError, "body must be a String or readable IO"
        end
        return Result.new(status: :too_large).freeze if raw.bytesize > max_email_bytes
        status = Verification.verify(body: raw, **options)
        return Result.new(status: status, bytes: raw.bytesize).freeze unless status == :ok
        message = VerifiedMessage.send(:new, body: raw, version: values["Signature-Version"],
          envelope: Envelope.decode(values["Envelope"]), provider_metadata: ProviderMetadata.decode(values["Metadata"]))
        Result.new(status: :ok, message: message, bytes: raw.bytesize).freeze
      end

      def self.deep_freeze(value)
        case value
        when Hash then value.each { |key, item| deep_freeze(key); deep_freeze(item) }
        when Array then value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end
    end
  end
end
