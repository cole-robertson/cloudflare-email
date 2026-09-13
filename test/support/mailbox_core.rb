require "minitest/autorun"
require "mailbox_kit/mailboxes"

abort "core loaded Cloudflare adapter" if $LOADED_FEATURES.any? { |path| path.end_with?("/cloudflare-email.rb", "/cloudflare/email/client.rb") }
if ENV["MAILBOX_KIT_EXPECTED_ROOT"]
  abort "core loaded from source" unless MailboxKit::ROOT == ENV.fetch("MAILBOX_KIT_EXPECTED_ROOT")
end
require "generators/mailbox_kit/install/templates/create_mailbox_kit_receiving_domains"
require "generators/mailbox_kit/install/templates/create_mailbox_kit_mailboxes"
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false
CreateMailboxKitReceivingDomains.new.migrate(:up)
CreateMailboxKitMailboxes.new.migrate(:up)

class StandaloneMailboxCoreTest < Minitest::Test
  Box = MailboxKit::Mailboxes

  def test_inbound_lookup_is_indexed
    assert ActiveRecord::Base.connection.index_exists?(:cloudflare_email_mailbox_messages, :inbound_email_id)
  end

  def setup
    [Box::Message, Box::Address, Box::Mailbox, Box::ReceivingDomain].each(&:delete_all)
    @domain = Box.register_domain(domain: "in.example.test", tenant_key: "workspace")
    Box.activate_domain!(@domain.id, evidence: "verified receiving transport")
  end

  def create_mailbox(session)
    box = session.create(name: "Inbox", address: "hello@in.example.test", owner_ref: "owner-uuid")
    session.activate_address!(box.addresses.first.id, evidence: "verified route")
    box
  end

  def test_provider_free_routing_and_suspended_reservations
    refute MailboxKit::Tenancy.enabled?
    assert_nil @domain.account_id
    session_outside = nil
    Box.for_tenant("workspace") do |session|
      session_outside = session
      mailbox = create_mailbox(session)
      session.enable_catch_all(mailbox.addresses.first.id, evidence: "verified catch-all")
      reserved = session.add_address(mailbox.id, address: "reserved@in.example.test")
      session.suspend_address(mailbox.id, reserved.id)
      Box.with_recipient(recipient: "unlisted@in.example.test") do |destination|
        assert destination.catch_all
        assert_equal mailbox.id, destination.mailbox_id
        assert_equal "owner-uuid", destination.owner_ref
      end
      assert_raises(Box::Unavailable) { Box.with_recipient(recipient: reserved.address) {} }
      session.suspend(mailbox.id)
      assert_raises(Box::Unavailable) { Box.with_recipient(recipient: "hello@in.example.test") {} }
    end
    assert_raises(MailboxKit::ConfigurationError) { session_outside.mailboxes }
    assert_nil MailboxKit::Tenancy.current_key
  end

  def test_membership_transaction_rolls_back_on_application_failure
    Box.for_tenant("workspace") { |session| create_mailbox(session) }
    assert_raises(RuntimeError) do
      Box.receive(recipient: "hello@in.example.test") do |destination|
        Box::Mailbox.find(destination.mailbox_id).update!(name: "Changed")
        raise "host persistence failed"
      end
    end
    assert_equal "Inbox", Box::Mailbox.first.name
    assert_equal 0, Box::Message.count
  end

  def test_loading_cloudflare_does_not_require_outbox_or_account_for_core_mailboxes
    return unless ENV["MAILBOX_KIT_MIXED"]
    require "cloudflare/email/mailboxes"
    assert_same Box, Cloudflare::Email::Mailboxes
    assert_same MailboxKit::Tenancy, Cloudflare::Email::Tenancy
    assert @domain.reload.valid?
    refute ActiveRecord::Base.connection.data_source_exists?("cloudflare_email_outbound_deliveries")
    Box.for_tenant("workspace") do
      mailbox = Box::Mailbox.create!(name: "Empty", tenant_key: "workspace")
      mailbox.destroy!
      assert mailbox.destroyed?
    end
  end
end
