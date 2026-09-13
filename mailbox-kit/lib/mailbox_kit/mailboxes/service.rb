require "mailbox_kit/address_syntax"

module MailboxKit
  module Mailboxes
    # A routing snapshot, not a model or an authorization token. Use it inside
    # the yielded tenant context; later jobs must resolve/check policy again.
    Destination = Struct.new(:tenant_key, :mailbox_id, :address_id,
      :receiving_domain_id, :recipient, :owner_ref, :catch_all, keyword_init: true) do
      def initialize(**attributes)
        super(**{ catch_all: false }.merge(attributes).transform_values { |value| value.is_a?(String) ? value.dup.freeze : value })
        freeze
      end
    end

    class << self
      # Call after host authorization. The directory is a control-plane API,
      # not a public endpoint accepting arbitrary customer domain claims.
      def register_domain(domain:, tenant_key:, account_id: nil)
        Tenancy.normalize_key(tenant_key)
        ReceivingDomain.create!(domain: domain, tenant_key: tenant_key, account_id: account_id)
      end

      def activate_domain!(id, evidence:, sending_enabled: false)
        raise ArgumentError, "verification evidence is required" if evidence.to_s.strip.empty?
        domain = ReceivingDomain.find(id)
        domain.update!(state: "active", provisioning_evidence: evidence,
          verified_at: Time.now.utc, sending_enabled: sending_enabled)
        domain
      end

      def for_tenant(key)
        raise ArgumentError, "a block is required" unless block_given?
        Tenancy.with(key) { yield Session.new(key) }
      end

      # Only call after authenticating ingress and its envelope. Resolve before
      # ActionMailbox or ActiveStorage accesses a tenant connection.
      def receive(recipient:, source: nil, &block)
        raise ArgumentError, "provide source or a persistence block, not both" if source && block
        raise ArgumentError, "source or persistence block required" unless source || block
        in_recipient_tenant(recipient) do |session, address, directory|
          session.receive(address, directory) do |destination|
            if block
              # Legacy custom persistence blocks must return the existing Rails
              # record on duplicates when membership attachment is desired.
              block.lambda? && block.arity.zero? ? block.call : block.call(destination)
            else
              require "mailbox_kit/inbound_email"
              InboundEmail.persist(source: source).record
            end
          end
        end
      end

      # Lookup only: the host owns persistence and the block's return value.
      # Verify ingress before calling this API. No ActionMailbox is required.
      def with_recipient(recipient:)
        raise ArgumentError, "a block is required" unless block_given?
        in_recipient_tenant(recipient) do |session, address, directory|
          session.with_recipient(address, directory) { |destination| yield destination }
        end
      end

      def canonical_address(value)
        unless AddressSyntax.valid_address?(value)
          raise ValidationError, "mailbox address must be an ASCII dot-atom address"
        end
        value.downcase
      end

      private

      def in_recipient_tenant(recipient)
        address = canonical_address(recipient)
        directory = ReceivingDomain.find_by(domain: address.split("@", 2).last, state: "active")
        raise Unavailable, "receiving domain unavailable" unless directory
        for_tenant(directory.tenant_key) do |session|
          yield session, address, directory
        end
      end
    end

    class Session
      attr_reader :tenant_key

      def initialize(tenant_key)
        @tenant_key = tenant_key
      end

      def mailboxes
        context!
        Mailbox.where(tenant_key: tenant_key)
      end

      def create(name:, address:, owner_ref: nil)
        context!
        Mailbox.transaction do
          mailbox = Mailbox.create!(tenant_key: tenant_key, name: name, owner_ref: owner_ref)
          add_address(mailbox.id, address: address)
          mailbox
        end
      end

      def add_address(mailbox_id, address:)
        mailbox = active_mailbox!(mailbox_id)
        canonical = Mailboxes.canonical_address(address)
        local, domain = canonical.split("@", 2)
        directory = ReceivingDomain.find_by!(domain: domain, tenant_key: tenant_key, state: "active")
        Address.create!(tenant_key: tenant_key, mailbox_id: mailbox.id,
          receiving_domain_id: directory.id, local_part: local, domain: domain,
          address: canonical, state: "pending")
      end

      def activate_address!(address_id, evidence:)
        context!
        raise ArgumentError, "route verification evidence is required" if evidence.to_s.strip.empty?
        address = Address.where(tenant_key: tenant_key).find(address_id)
        active_mailbox!(address.mailbox_id)
        active_domain!(address)
        address.update!(state: "active", provisioning_evidence: evidence)
        address
      end

      # This records the host's verified provider routing decision; it does
      # not provision provider DNS/rules or authorize arbitrary From values.
      def enable_catch_all(address_id, evidence:)
        context!
        catch_all_schema!
        raise ArgumentError, "catch-all route verification evidence is required" if evidence.to_s.strip.empty?
        Address.transaction do
          address = Address.where(tenant_key: tenant_key, state: "active").find(address_id)
          active_mailbox!(address.mailbox_id)
          active_domain!(address)
          address.update!(catch_all: true, catch_all_evidence: evidence)
          address
        end
      end

      def disable_catch_all(address_id)
        context!
        catch_all_schema!
        # Disabling is permitted even after suspension; retain the previous
        # verification evidence for operator inspection.
        Address.where(tenant_key: tenant_key).find(address_id).tap { |address| address.update!(catch_all: false) }
      end

      def suspend(mailbox_id)
        mailboxes.find(mailbox_id).tap { |mailbox| mailbox.update!(state: "suspended") }
      end

      def resume(mailbox_id)
        mailboxes.find(mailbox_id).tap { |mailbox| mailbox.update!(state: "active") }
      end

      def messages(mailbox_id)
        mailbox = mailboxes.find(mailbox_id)
        Message.where(tenant_key: tenant_key, mailbox_id: mailbox.id)
      end

      def addresses(mailbox_id)
        mailbox = mailboxes.find(mailbox_id)
        Address.where(tenant_key: tenant_key, mailbox_id: mailbox.id)
      end

      def suspend_address(mailbox_id, address_id)
        addresses(mailbox_id).find(address_id).tap { |address| address.update!(state: "suspended") }
      end

      def inbound_email(mailbox_id, message_id)
        message = messages(mailbox_id).find(message_id)
        ensure_storage_connection!
        ::ActionMailbox::InboundEmail.find(message.inbound_email_id)
      end

      # For an existing Rails ingress or ApplicationMailbox handler. The caller
      # has already selected this trusted tenant and authorized the inbound ID.
      # Never accept an unscoped ID from a customer or switch tenants around a
      # model object loaded from another database.
      def attach(recipient:, inbound_email_id:)
        context!
        ensure_storage_connection!
        address = Mailboxes.canonical_address(recipient)
        directory = ReceivingDomain.find_by!(domain: address.split("@", 2).last,
          tenant_key: tenant_key, state: "active")
        destination = resolve_destination(address, directory)
        attach_destination(destination, inbound_email_id)
      end

      # Explicit permanent removal. Archive is the reversible default.
      # Other mailbox memberships retain their shared raw source.
      def purge_message(mailbox_id, message_id)
        context!
        ensure_storage_connection!
        Message.transaction do
          message = messages(mailbox_id).find(message_id)
          inbound_id = message.inbound_email_id
          inbound = ::ActionMailbox::InboundEmail.find_by(id: inbound_id)
          if inbound
            inbound.with_lock do
              message.destroy!
              inbound.destroy! unless Message.where(inbound_email_id: inbound_id).exists?
            end
          else
            message.destroy!
          end
        end
      end

      def mark_read(mailbox_id, message_id, read: true)
        messages(mailbox_id).find(message_id).update!(read_at: read ? Time.now.utc : nil)
      end

      def archive(mailbox_id, message_id, archived: true)
        messages(mailbox_id).find(message_id).update!(archived_at: archived ? Time.now.utc : nil)
      end

      def receive(address, directory)
        context!
        ensure_storage_connection! if defined?(::ActionMailbox::InboundEmail)
        Mailbox.transaction do
          destination = resolve_destination(address, directory)
          inbound = yield destination
          if inbound
            if defined?(::ActionMailbox::InboundEmail)
              attach_destination(destination, inbound.id)
            else
              # Compatibility for host-owned storage. New integrations should
              # use with_recipient for custom stores, or attach for Rails mail.
              record_membership(destination, inbound.id)
            end
          end
          inbound
        end
      end

      def with_recipient(address, directory)
        context!
        yield resolve_destination(address, directory)
      end

      private

      def attach_destination(destination, inbound_email_id)
        inbound = ::ActionMailbox::InboundEmail.find(inbound_email_id)
        inbound.with_lock do
          if Message.where(inbound_email_id: inbound.id).where.not(tenant_key: tenant_key).exists?
            raise ConfigurationError, "inbound email already belongs to another tenant"
          end
          record_membership(destination, inbound.id)
        end
      end

      def record_membership(destination, inbound_email_id)
        Message.create_or_find_by!(tenant_key: tenant_key, mailbox_id: destination.mailbox_id,
          inbound_email_id: inbound_email_id) { |row| row.recipient = destination.recipient }
      end

      def resolve_destination(address, directory)
        destination = Address.where(tenant_key: tenant_key, address: address,
          receiving_domain_id: directory.id).first
        fallback = destination.nil?
        if fallback && catch_all_schema_available?
          destination = Address.where(tenant_key: tenant_key, receiving_domain_id: directory.id,
            catch_all: true, state: "active").first
        end
        # An exact pending/suspended address intentionally reserves its name.
        # It must never fall through to another mailbox's catch-all.
        raise Unavailable, "mailbox address unavailable" unless destination&.state == "active"
        mailbox = active_mailbox!(destination.mailbox_id)
        active_domain!(destination)
        Destination.new(tenant_key: tenant_key, mailbox_id: mailbox.id,
          address_id: destination.id, receiving_domain_id: directory.id,
          recipient: address, owner_ref: mailbox.owner_ref, catch_all: fallback)
      rescue ::ActiveRecord::RecordNotFound
        raise Unavailable, "mailbox address unavailable"
      end

      def context!
        raise ConfigurationError, "mailbox session used outside its tenant context" unless Tenancy.require_context! == tenant_key
      end

      def catch_all_schema_available?
        Address.connection.column_exists?(Address.table_name, :catch_all) &&
          Address.connection.column_exists?(Address.table_name, :catch_all_evidence)
      end

      def catch_all_schema!
        unless catch_all_schema_available?
          raise ConfigurationError, "run mailbox_kit:install migrations for this tenant first"
        end
      end

      def ensure_storage_connection!
        unless defined?(::ActionMailbox::InboundEmail) && ::ActionMailbox::InboundEmail.connection_pool == Mailbox.connection_pool &&
            ::ActiveStorage::Blob.connection_pool == Mailbox.connection_pool
          raise ConfigurationError, "ActionMailbox, ActiveStorage and mailbox records must share the tenant connection"
        end
      end

      def active_mailbox!(id)
        context!
        mailboxes.where(state: "active").find(id)
      end

      def active_domain!(address)
        ReceivingDomain.find_by!(id: address.receiving_domain_id, domain: address.domain,
          tenant_key: tenant_key, state: "active")
      end

    end
  end
end
