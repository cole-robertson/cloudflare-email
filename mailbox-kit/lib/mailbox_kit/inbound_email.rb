require "mailbox-kit"
require "digest"
require "stringio"

module MailboxKit
  # A small bridge to Rails' existing storage and routing lifecycle. It returns
  # the existing record on duplicate delivery so callers can attach memberships.
  #
  # The raw source is uploaded BEFORE any transaction this module opens. A
  # database transaction can hold a write lock (SQLite's from BEGIN when
  # transactions are immediate), so a storage round trip inside one stalls
  # every other writer. Call .prepare outside the caller's transaction too
  # (Mailboxes.receive does) and only rows are written while it is open.
  module InboundEmail
    Result = Struct.new(:record, :created, keyword_init: true) do
      def created? = created
    end

    def self.persist(source:, message_id: nil, message_checksum: nil, metadata: {})
      prepare(source: source, message_id: message_id, message_checksum: message_checksum,
        metadata: metadata).persist
    end

    # Resolves the identity and, unless a record already has it, uploads the raw
    # email. Call in the tenant that will own the record, outside any
    # transaction; then call #persist on the result.
    def self.prepare(source:, message_id: nil, message_checksum: nil, metadata: {})
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
      Prepared.new(source, identity, metadata).tap(&:upload)
    end

    class Prepared
      # The tenant the bytes were uploaded under, for a #discard run later.
      attr_reader :tenant_key

      def initialize(source, identity, metadata)
        @source, @identity, @metadata = source, identity, metadata
        @tenant_key = Tenancy.current_key if defined?(Tenancy)
      end

      # Uploads the bytes unless a record with this identity already exists.
      def upload
        return if @blob || model.uncached { model.exists?(@identity) }

        blob = ::ActiveStorage::Blob.new(filename: "message.eml", content_type: "message/rfc822",
          service_name: ::ActionMailbox.storage_service, metadata: @metadata.to_h)
        io = StringIO.new(@source)
        blob.unfurl(io)
        blob.upload_without_unfurling(io)
        @blob = blob
      end

      # Writes the record and its blob row, or returns the record a concurrent
      # delivery already wrote. Uploaded bytes no committed row will name are
      # deleted once no transaction is open.
      def persist
        result = model.transaction do
          # Uncached: a request's query cache would repeat #upload's answer.
          if (existing = model.uncached { model.find_by(@identity) })
            next Result.new(record: existing, created: false).freeze
          end
          # Rare: a record existed when #upload looked and is gone now.
          upload
          # Rails returns nil on a unique conflict. Roll back that savepoint before
          # looking up the winner, including on PostgreSQL's aborted transactions.
          record = model.transaction(requires_new: true) do
            model.create!(raw_email: @blob, **@identity)
          rescue ::ActiveRecord::RecordNotUnique
            raise ::ActiveRecord::Rollback
          end
          Result.new(record: record || model.uncached { model.find_by!(@identity) }, created: !record.nil?).freeze
        end
        discard unless result.created?
        result
      rescue StandardError
        discard unless model.connection.transaction_open?
        raise
      end

      # Deletes the uploaded bytes unless a committed row names them. Run after
      # the transaction that would have committed that row has finished.
      def discard
        return unless @blob
        return if ::ActiveStorage::Blob.uncached { ::ActiveStorage::Blob.exists?(key: @blob.key) }

        @blob.service.delete(@blob.key)
        @blob = nil
      rescue StandardError => error
        warn "mailbox-kit: raw email #{@blob&.key} not deleted: #{error.class}: #{error.message}"
      end

      private

      def model = ::ActionMailbox::InboundEmail
    end
  end
end
