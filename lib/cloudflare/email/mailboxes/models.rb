require "active_record"
require "cloudflare/email/active_record/base"

module Cloudflare
  module Email
    module Mailboxes
      # Domains are an administrator-maintained receiving directory. An active
      # record is an assertion by the application, not DNS ownership verification.
      class ReceivingDomain < Mailboxes.directory_base
        self.table_name = "cloudflare_email_receiving_domains"
        STATES = %w[pending active suspended].freeze
        attr_readonly :domain, :tenant_key, :account_id
        before_validation(on: :create) { self.domain = domain.to_s.strip.downcase }
        validates :tenant_key, :account_id, presence: true
        validates :domain, presence: true, uniqueness: true,
          length: { maximum: 253 },
          format: { with: /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+\z/ }
        validates :state, inclusion: { in: STATES }
        validate do
          errors.add(:domain, "has an oversized label") if domain.to_s.split(".").any? { |label| label.length > 63 }
        end
        scope :active, -> { where(state: "active") }
      end

      module TenantIdentity
        extend ActiveSupport::Concern
        included do
          attr_readonly :tenant_key
          validates :tenant_key, presence: true
          before_validation :assign_tenant_identity
          validate :validate_tenant_identity
          before_destroy :assert_tenant_identity!
        end

        private

        def assign_tenant_identity
          self.tenant_key ||= Tenancy.current_key
        end

        def validate_tenant_identity
          return unless Tenancy.enabled? || Tenancy.current_key
          Tenancy.require_context!
          errors.add(:tenant_key, "does not match the current tenant") unless tenant_key == Tenancy.current_key
        end

        def assert_tenant_identity!
          return unless Tenancy.enabled? || Tenancy.current_key
          Tenancy.require_context!
          raise ArgumentError, "record belongs to another tenant" unless tenant_key == Tenancy.current_key
        end

        def validate_parent_tenant(parent, attribute)
          errors.add(attribute, "belongs to another tenant") if parent && parent.tenant_key != tenant_key
        end
      end

      class Mailbox < Cloudflare::Email::ActiveRecord::Base
        include TenantIdentity
        self.table_name = "cloudflare_email_mailboxes"
        has_many :addresses, class_name: "Cloudflare::Email::Mailboxes::Address", dependent: :restrict_with_exception
        has_many :messages, class_name: "Cloudflare::Email::Mailboxes::Message", dependent: :restrict_with_exception
        has_many :outbound_messages, class_name: "Cloudflare::Email::Mailboxes::OutboundMessage", dependent: :restrict_with_exception
        validates :name, presence: true, length: { maximum: 255 }
        validates :state, inclusion: { in: %w[active suspended] }
        scope :active, -> { where(state: "active") }
      end

      class Address < Cloudflare::Email::ActiveRecord::Base
        include TenantIdentity
        self.table_name = "cloudflare_email_addresses"
        belongs_to :mailbox, class_name: "Cloudflare::Email::Mailboxes::Mailbox"
        attr_readonly :mailbox_id, :receiving_domain_id, :local_part, :domain, :address
        before_validation :normalize_address, on: :create
        validates :mailbox, :receiving_domain_id, presence: true
        validates :local_part, length: { in: 1..64 },
          format: { with: /\A[a-z0-9!\#$%&'*+\/=\?^_`{|}~-]+(?:\.[a-z0-9!\#$%&'*+\/=\?^_`{|}~-]+)*\z/ }
        validates :address, uniqueness: true, length: { maximum: 254 }
        validates :state, inclusion: { in: %w[pending active suspended] }
        validate :validate_directory
        validate :validate_catch_all
        validate { validate_parent_tenant(mailbox, :mailbox) }
        scope :active, -> { where(state: "active") }

        def receiving_domain
          ReceivingDomain.find_by(id: receiving_domain_id)
        end

        private

        def normalize_address
          self.local_part = local_part.to_s.strip.downcase
          self.domain = domain.to_s.strip.downcase
          self.address = "#{local_part}@#{domain}"
        end

        def validate_directory
          registered = receiving_domain
          unless registered && registered.domain == domain && registered.tenant_key == tenant_key
            errors.add(:receiving_domain_id, "must match this tenant and domain")
            return
          end
          if new_record? && registered.state != "active"
            errors.add(:receiving_domain_id, "must be active before creating addresses")
          end
        end

        def validate_catch_all
          # Existing exact-address installations need not migrate until they
          # opt into catch-all receiving.
          return unless has_attribute?(:catch_all) && self[:catch_all]
          errors.add(:catch_all_evidence, "is required") if self[:catch_all_evidence].to_s.strip.empty?
          if will_save_change_to_catch_all? && state != "active"
            errors.add(:catch_all, "requires an active address")
          end
          return unless state == "active"
          errors.add(:catch_all, "requires an active mailbox") unless mailbox&.state == "active"
          errors.add(:catch_all, "requires an active receiving domain") unless receiving_domain&.state == "active"
          if self.class.where(receiving_domain_id: receiving_domain_id, catch_all: true, state: "active").where.not(id: id).exists?
            errors.add(:catch_all, "already exists for this receiving domain")
          end
        end
      end

      class Message < Cloudflare::Email::ActiveRecord::Base
        include TenantIdentity
        self.table_name = "cloudflare_email_mailbox_messages"
        belongs_to :mailbox, class_name: "Cloudflare::Email::Mailboxes::Mailbox"
        attr_readonly :mailbox_id, :inbound_email_id, :recipient
        validates :mailbox, :inbound_email_id, :recipient, presence: true
        # The unique database index also supports create_or_find_by! retries.
        validate { validate_parent_tenant(mailbox, :mailbox) }
        scope :unread, -> { where(read_at: nil) }
        scope :inbox, -> { where(archived_at: nil) }

        def mark_read!
          update!(read_at: Time.current)
        end

        def mark_unread!
          update!(read_at: nil)
        end

        def archive!
          update!(archived_at: Time.current)
        end

        def unarchive!
          update!(archived_at: nil)
        end
      end

      class OutboundMessage < Cloudflare::Email::ActiveRecord::Base
        include TenantIdentity
        self.table_name = "cloudflare_email_mailbox_outbound_messages"
        belongs_to :mailbox, class_name: "Cloudflare::Email::Mailboxes::Mailbox"
        belongs_to :outbound_delivery, class_name: "Cloudflare::Email::ActiveRecord::OutboundDelivery"
        attr_readonly :mailbox_id, :outbound_delivery_id
        validates :mailbox, :outbound_delivery, presence: true
        # Enforce uniqueness in the database so idempotent link creation works.
        validate { validate_parent_tenant(mailbox, :mailbox) }
      end
    end
  end
end
