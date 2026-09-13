require "digest"
require "mailbox_kit/mailboxes/service"
module Cloudflare
  module Email
    module Mailboxes
      # Provider-specific behavior is installed only when the Cloudflare
      # integration is explicitly loaded. Core sessions remain receiving-only.
      module CloudflareSession
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

        def outbound_messages(mailbox_id)
          mailbox = mailboxes.find(mailbox_id)
          OutboundMessage.where(tenant_key: tenant_key, mailbox_id: mailbox.id)
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
          raise Unavailable, "domain is not enabled for Cloudflare sending" if domain.account_id.to_s.strip.empty?
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
          raise Unavailable, "domain is not enabled for Cloudflare sending" if domain.account_id.to_s.strip.empty?
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

        private
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
      Session.include(CloudflareSession)
    end
  end
end
