require "digest"
require "cloudflare/email/envelope"

module Cloudflare
  module Email
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
        def register_domain(domain:, tenant_key:, account_id:)
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

        # Only call after verifying the complete ingress HMAC. Resolve before
        # ActionMailbox or ActiveStorage accesses a tenant connection.
        def receive(recipient:, &block)
          raise ArgumentError, "persistence block required" unless block
          in_recipient_tenant(recipient) do |session, address, directory|
            session.receive(address, directory) do |destination|
              # Preserve strict callbacks accepted before destinations were yielded.
              block.lambda? && block.arity.zero? ? block.call : block.call(destination)
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
          unless Envelope.valid_address?(value)
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

        def provision_address!(address_id, provisioner:, worker_name:)
          context!
          raise ArgumentError, "provision outside a database transaction" if Address.connection.transaction_open?
          address = Address.where(tenant_key: tenant_key).find(address_id)
          active_mailbox!(address.mailbox_id)
          active_domain!(address)
          provisioner.provision(address: address.address, worker_name: worker_name)
          # Failed requests leave the address pending; the existing provisioner
          # upserts a rule, making a deliberate retry safe.
          activate_address!(address.id, evidence: "Cloudflare address rule provisioned for Worker #{worker_name}")
        end

        # This records the host's verified provider routing decision; it does
        # not provision Cloudflare DNS/rules or authorize arbitrary From values.
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

        def outbound_messages(mailbox_id)
          mailbox = mailboxes.find(mailbox_id)
          OutboundMessage.where(tenant_key: tenant_key, mailbox_id: mailbox.id)
        end

        def inbound_email(mailbox_id, message_id)
          message = messages(mailbox_id).find(message_id)
          ensure_storage_connection!
          ::ActionMailbox::InboundEmail.find(message.inbound_email_id)
        end

        # Explicit permanent removal. Archive is the reversible default.
        # Other mailbox memberships retain their shared raw source.
        def purge_message(mailbox_id, message_id)
          context!
          ensure_storage_connection!
          Message.transaction do
            message = messages(mailbox_id).find(message_id)
            inbound_id = message.inbound_email_id
            message.destroy!
            unless Message.where(inbound_email_id: inbound_id).exists?
              ::ActionMailbox::InboundEmail.find_by(id: inbound_id)&.destroy!
            end
          end
        end

        def mark_read(mailbox_id, message_id, read: true)
          messages(mailbox_id).find(message_id).update!(read_at: read ? Time.now.utc : nil)
        end

        def archive(mailbox_id, message_id, archived: true)
          messages(mailbox_id).find(message_id).update!(archived_at: archived ? Time.now.utc : nil)
        end

        def prepare(mailbox_id, operation_key:, mail:)
          context!
          raise ArgumentError, "operation_key is required" unless operation_key.is_a?(String) && !operation_key.strip.empty?
          mail = mail.message if mail.respond_to?(:message) && !mail.respond_to?(:encoded)
          raise ValidationError, "mail must be a rendered Mail message" unless mail.respond_to?(:encoded)
          mailbox = active_mailbox!(mailbox_id)
          from = Array(mail.from)
          raise ValidationError, "mail must have one mailbox From address" unless from.length == 1
          sender = Array(mail.sender)
          address = authorized_sender!(mailbox, from.first)
          envelope_from = mail.respond_to?(:smtp_envelope_from) ? mail.smtp_envelope_from : from.first
          unless Mailboxes.canonical_address(envelope_from) == address.address &&
              sender.all? { |value| Mailboxes.canonical_address(value) == address.address }
            raise ValidationError, "MIME and envelope sender must match the mailbox address"
          end
          domain = active_domain!(address)
          raise Unavailable, "domain is not enabled for sending" unless domain.sending_enabled
          key = "mailbox:#{Digest::SHA256.hexdigest(JSON.generate([tenant_key, mailbox.id, operation_key]))}"
          Mailbox.transaction do
            delivery = ActiveRecord::Outbox.prepare_mail(account_id: domain.account_id, operation_key: key, mail: mail)
            OutboundMessage.create_or_find_by!(tenant_key: tenant_key, mailbox_id: mailbox.id,
              outbound_delivery_id: delivery.id)
            delivery
          end
        end

        # Enqueue only after the outer transaction commits. No mail or model
        # GlobalIDs are serialized into this job, just stable identities.
        def enqueue(mailbox_id, operation_key:)
          context!
          raise ArgumentError, "enqueue after database commit" if Mailbox.connection.transaction_open?
          linked_delivery!(mailbox_id, operation_key)
          SendJob.perform_later(tenant_key, mailbox_id, operation_key)
        end

        def deliver(mailbox_id, operation_key:)
          mailbox = active_mailbox!(mailbox_id)
          delivery = linked_delivery!(mailbox.id, operation_key)
          address = authorized_sender!(mailbox, delivery.from_address)
          domain = active_domain!(address)
          raise Unavailable, "domain is not enabled for sending" unless domain.sending_enabled && domain.account_id == delivery.account_id
          ActiveRecord::Outbox.deliver(delivery, client: Mailboxes.client_for(tenant_key, delivery.account_id))
          handler = Mailboxes.delivery_handler
          delivery.with_lock { handler.call(delivery) } if handler.respond_to?(:call)
          Events.register(delivery, tenant_key: tenant_key) if %w[accepted partial].include?(delivery.state) && delivery.provider_message_id
          delivery
        end

        def reconcile(mailbox_id, operation_key:, **evidence, &handler)
          delivery = linked_delivery!(mailbox_id, operation_key)
          raise ArgumentError, "reconcile outside an outer transaction" if Mailbox.connection.transaction_open?
          ActiveRecord::Outbox.reconcile(delivery, **evidence, &handler)
          Events.register(delivery, tenant_key: tenant_key) if %w[accepted partial].include?(delivery.state) && delivery.provider_message_id
          delivery
        end

        # A bounded repair pass after an enqueue gap or cross-database commit
        # gap. Does not automatically resend sending/unknown/rejected rows.
        def recover(limit: 100, after_id: 0)
          context!
          raise ArgumentError, "recover outside a database transaction" if Mailbox.connection.transaction_open?
          raise ArgumentError, "limit must be 1..1000" unless limit.is_a?(Integer) && (1..1000).cover?(limit)
          raise ArgumentError, "after_id must be nonnegative" unless after_id.is_a?(Integer) && after_id >= 0
          links = OutboundMessage.where(tenant_key: tenant_key).where("id > ?", after_id).order(:id).limit(limit).to_a
          links.each do |link|
            delivery = ActiveRecord::OutboundDelivery.find(link.outbound_delivery_id)
            if delivery.state == "prepared"
              enqueue(link.mailbox_id, operation_key: delivery.operation_key) if mailboxes.find(link.mailbox_id).state == "active"
            elsif %w[accepted partial].include?(delivery.state)
              handler = Mailboxes.delivery_handler
              delivery.with_lock { handler.call(delivery) } if handler.respond_to?(:call)
              Events.register(delivery, tenant_key: tenant_key) if delivery.provider_message_id
            end
          end
          links.last&.id
        end

        def receive(address, directory)
          context!
          ensure_storage_connection! if defined?(::ActionMailbox::InboundEmail)
          Mailbox.transaction do
            destination = resolve_destination(address, directory)
            inbound = yield destination
            Message.create_or_find_by!(tenant_key: tenant_key, mailbox_id: destination.mailbox_id,
              inbound_email_id: inbound.id) { |row| row.recipient = address } if inbound
            inbound
          end
        end

        def with_recipient(address, directory)
          context!
          yield resolve_destination(address, directory)
        end

        private

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
            raise ConfigurationError, "run cloudflare:email:mailboxes:catch_all migrations for this tenant first"
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

        def authorized_sender!(mailbox, address)
          Address.where(tenant_key: tenant_key, mailbox_id: mailbox.id, state: "active")
            .find_by!(address: Mailboxes.canonical_address(address))
        end

        def linked_delivery!(mailbox_id, operation_key)
          mailbox = mailboxes.find(mailbox_id)
          delivery = ActiveRecord::OutboundDelivery.find_by!(operation_key: operation_key)
          OutboundMessage.find_by!(tenant_key: tenant_key, mailbox_id: mailbox.id, outbound_delivery_id: delivery.id)
          delivery
        end
      end
    end
  end
end
