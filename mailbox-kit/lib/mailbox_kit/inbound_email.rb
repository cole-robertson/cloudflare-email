require "mailbox-kit"
require "digest"

module MailboxKit
  # A small bridge to Rails' existing storage and routing lifecycle. It returns
  # the existing record on duplicate delivery so callers can attach memberships.
  module InboundEmail
    Result = Struct.new(:record, :created, keyword_init: true) do
      def created? = created
    end

    def self.persist(source:, message_id: nil, message_checksum: nil, metadata: {})
      unless defined?(::ActionMailbox::InboundEmail)
        raise ConfigurationError, "load ActionMailbox before persisting inbound mail"
      end
      raise ArgumentError, "source must be a String" unless source.is_a?(String)
      source = source.b
      scope = Tenancy.require_context! if defined?(Tenancy) && (Tenancy.enabled? || Tenancy.current_key)
      # Two tenant scopes can share a database. Sharing bytes must not suppress
      # the other tenant's Rails routing job. Recipients within one scope can
      # share the same record and have independent inbox memberships.
      checksum = message_checksum || if scope
        Digest::SHA256.new.update("mailbox-kit\0#{scope.bytesize}:#{scope}\0").update(source).hexdigest
      else
        Digest::SHA1.hexdigest(source)
      end
      unless message_id
        message_id = begin
          ::Mail.from_source(source).message_id
        rescue StandardError
          nil
        end
      end
      identity = { message_id: message_id || "#{checksum}@mailbox-kit.invalid",
                   message_checksum: checksum }
      model = ::ActionMailbox::InboundEmail
      model.transaction do
        if (existing = model.find_by(identity))
          next Result.new(record: existing, created: false).freeze
        end
        # Rails returns nil on a unique conflict. Roll back that savepoint before
        # looking up the winner, including on PostgreSQL's aborted transactions.
        record = model.transaction(requires_new: true) do
          created = model.create_and_extract_message_id!(source, **identity)
          raise ::ActiveRecord::Rollback unless created
          unless metadata.empty?
            blob = created.raw_email.blob
            blob.update!(metadata: blob.metadata.merge(metadata))
          end
          created
        end
        Result.new(record: record || model.find_by!(identity), created: !record.nil?).freeze
      end
    end
  end
end
