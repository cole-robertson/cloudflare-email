require "bundler/setup"
require "minitest/autorun"
require "active_record"
ActiveRecord.raise_on_assign_to_attr_readonly = true
require "tmpdir"
require "cloudflare-email"

module Cloudflare::Email::Mailboxes
  def self.directory_base
    ::ActiveRecord::Base
  end
end
require "cloudflare/email/mailboxes/models"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false
templates = File.expand_path("../../lib/generators/cloudflare/email", __dir__)
require File.join(templates, "outbox/templates/create_cloudflare_email_outbox")
require File.join(templates, "mailboxes/templates/create_cloudflare_email_receiving_domains")
require File.join(templates, "mailboxes/templates/create_cloudflare_email_mailboxes")
CreateCloudflareEmailOutbox.new.migrate(:up)
CreateCloudflareEmailReceivingDomains.new.migrate(:up)
CreateCloudflareEmailMailboxes.new.migrate(:up)

class MailboxModelPersistenceTest < Minitest::Test
  Models = Cloudflare::Email::Mailboxes
  Tenancy = Cloudflare::Email::Tenancy

  def setup
    [Models::OutboundMessage, Models::Message, Models::Address, Models::Mailbox, Models::ReceivingDomain].each(&:delete_all)
    @domain = Models::ReceivingDomain.create!(domain: "CUSTOMER.Example.COM", tenant_key: "one", account_id: "cf", state: "active")
    @mailbox = Models::Mailbox.create!(tenant_key: "one", name: "Support", owner_ref: "customer:123")
  end

  def test_directory_normalizes_domain_and_rejects_invalid_or_duplicate_domains
    assert_equal "customer.example.com", @domain.domain
    assert_raises(ActiveRecord::RecordInvalid) do
      Models::ReceivingDomain.create!(domain: "Customer.example.com", tenant_key: "two", account_id: "cf")
    end
    %w[localhost bad..example.com -bad.example.com bad_.example.com].each do |domain|
      record = Models::ReceivingDomain.new(domain: domain, tenant_key: "one", account_id: "cf")
      refute record.valid?, domain
    end
  end

  def test_addresses_normalize_and_require_matching_active_directory
    record = create_address(local_part: "SUPPORT")
    assert_equal "support@customer.example.com", record.address
    assert_equal "pending", record.state
    assert_raises(ActiveRecord::RecordInvalid) { create_address(local_part: "support") }
    assert_raises(ActiveRecord::RecordInvalid) { create_address(local_part: "other", tenant_key: "two") }
    assert_raises(ActiveRecord::RecordInvalid) { create_address(local_part: "bad..part") }
    @domain.update!(state: "suspended")
    assert_raises(ActiveRecord::RecordInvalid) { create_address(local_part: "other") }
  end

  def test_record_identity_and_current_tenant_are_guarded
    record = create_address
    assert_raises(ActiveRecord::ReadonlyAttributeError) { record.update!(local_part: "renamed") }
    assert_equal "support", record.reload.local_part
    assert_equal "support@customer.example.com", record.address
    Tenancy.with("two") do
      refute @mailbox.valid?
      assert_raises(ArgumentError) { @mailbox.destroy! }
    end
    Tenancy.with("one") do
      child = Models::Mailbox.create!(name: "Sales")
      assert_equal "one", child.tenant_key
    end
  end

  def test_message_memberships_are_idempotent_and_have_inbox_state
    message = Models::Message.create!(tenant_key: "one", mailbox: @mailbox, inbound_email_id: 123, recipient: "support@customer.example.com")
    assert_equal 1, @mailbox.messages.inbox.unread.count
    message.mark_read!
    assert_equal 0, @mailbox.messages.unread.count
    message.archive!
    assert_equal 0, @mailbox.messages.inbox.count
    message.unarchive!
    message.mark_unread!
    assert_equal 1, @mailbox.messages.inbox.unread.count
    assert_raises(ActiveRecord::RecordNotUnique) do
      Models::Message.create!(tenant_key: "one", mailbox: @mailbox, inbound_email_id: 123, recipient: "alias@customer.example.com")
    end
    assert_raises(ActiveRecord::DeleteRestrictionError) { @mailbox.destroy! }
  end

  def test_strict_readonly_allows_lifecycle_updates_without_reassigning_identity
    address = create_address
    @domain.update!(state: "suspended")
    @domain.update!(state: "active", sending_enabled: true, provisioning_evidence: "Verified test domain")
    address.update!(state: "active", provisioning_evidence: "Verified test route")
    address.update!(state: "suspended")
    assert_equal "customer.example.com", @domain.reload.domain
    assert @domain.sending_enabled
    assert_equal "support@customer.example.com", address.reload.address
    assert_equal "suspended", address.state
    assert_raises(ActiveRecord::ReadonlyAttributeError) { @domain.domain = "other.example.com" }
    assert_raises(ActiveRecord::ReadonlyAttributeError) { address.address = "other@customer.example.com" }
  end

  private

  def create_address(**overrides)
    Models::Address.create!({ tenant_key: "one", mailbox: @mailbox, receiving_domain_id: @domain.id,
      domain: @domain.domain, local_part: "support" }.merge(overrides))
  end
end
