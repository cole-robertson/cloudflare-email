require_relative "../test_helper"
require "tmpdir"
require "fileutils"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "active_job/railtie"
require "active_storage/engine"
require "action_mailbox/engine"
require "cloudflare/email/engine"
require "cloudflare/email/tenancy"
require "cloudflare/email/mailboxes/configuration"
require "rack/test"

MAILBOX_INGRESS_ROOT = Dir.mktmpdir("cf-tenant-ingress")
ENV["RAILS_ENV"] = "test"
ENV["DATABASE_URL"] = "sqlite3:#{MAILBOX_INGRESS_ROOT}/directory.sqlite3"
ENV["CLOUDFLARE_INGRESS_SECRET"] = "test-ingress-secret"
Minitest.after_run do
  ActiveRecord::Base.connection_handler.clear_all_connections!
  FileUtils.remove_entry(MAILBOX_INGRESS_ROOT)
end

class MailboxDirectoryRecord < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "sqlite3", database: "#{MAILBOX_INGRESS_ROOT}/directory.sqlite3")
end
class MailboxTenantRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to shards: %i[alpha beta].to_h { |key|
    [key, { writing: { adapter: "sqlite3", database: "#{MAILBOX_INGRESS_ROOT}/#{key}.sqlite3" } }]
  }
end
Cloudflare::Email::Tenancy.configure(base_class: MailboxTenantRecord,
  switch: ->(key, &block) { MailboxTenantRecord.connected_to(role: :writing, shard: key.to_sym, &block) },
  current: -> { MailboxTenantRecord.current_shard.to_s })
Cloudflare::Email::Mailboxes.configure(directory_base: MailboxDirectoryRecord)
require "cloudflare/email/mailboxes"
require "cloudflare/email/verification"

# This fixture host uses Rails shards for framework records as well as gem
# records. Production hosts must configure their tenancy adapter equivalently.
module MailboxFrameworkConnection
  def connection_pool
    Cloudflare::Email::Tenancy.require_context!
    MailboxTenantRecord.connection_pool
  end
end

class MailboxIngressApp < Rails::Application
  config.root = MAILBOX_INGRESS_ROOT
  config.eager_load = false
  config.enable_reloading = false
  config.secret_key_base = "t" * 64
  config.hosts.clear
  config.logger = Logger.new(File::NULL)
  config.action_dispatch.show_exceptions = :none
  config.active_job.queue_adapter = :test
  config.action_mailbox.ingress = :cloudflare
  config.active_storage.service = :local
  config.active_storage.service_configurations = {
    local: {service: "Disk", root: "#{MAILBOX_INGRESS_ROOT}/blobs"}
  }
  config.to_prepare do
    ActionMailbox::Record.singleton_class.prepend(MailboxFrameworkConnection)
    ActiveStorage::Record.singleton_class.prepend(MailboxFrameworkConnection)
  end
end
MailboxIngressApp.initialize!

class ApplicationMailbox < ActionMailbox::Base
  routing all: :capture
end
class CaptureMailbox < ApplicationMailbox
  class_attribute :captures, default: []
  def process
    self.class.captures += [[Cloudflare::Email::Tenancy.require_context!, inbound_email.id,
      mail.subject, inbound_email.raw_email.download]]
  end
end

ActiveRecord::Migration.verbose = false
%w[activestorage actionmailbox].each do |name|
  Dir["#{Gem.loaded_specs.fetch(name).full_gem_path}/db/migrate/*.rb"].each { |path| require path }
end
%w[outbox/templates/create_cloudflare_email_outbox tracking/templates/create_cloudflare_email_event_receipts
   mailboxes/templates/create_cloudflare_email_receiving_domains mailboxes/templates/create_cloudflare_email_mailboxes
   mailboxes/templates/create_cloudflare_email_shared_events].each { |path| require "generators/cloudflare/email/#{path}" }
CreateCloudflareEmailReceivingDomains.new.migrate(:up)
CreateCloudflareEmailSharedEvents.new.migrate(:up)
%w[alpha beta].each do |key|
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: "#{MAILBOX_INGRESS_ROOT}/#{key}.sqlite3")
  [CreateActiveStorageTables, CreateActionMailboxTables, CreateCloudflareEmailOutbox,
   CreateCloudflareEmailEventReceipts, CreateCloudflareEmailMailboxes].each { |migration| migration.new.migrate(:up) }
  directory = Cloudflare::Email::Mailboxes.register_domain(domain: "#{key}.example.com", tenant_key: key, account_id: "account")
  Cloudflare::Email::Mailboxes.activate_domain!(directory.id, evidence: "isolated test setup")
  Cloudflare::Email::Mailboxes.for_tenant(key) do |session|
    box = session.create(name: "Support", address: "support@#{key}.example.com")
    session.activate_address!(box.addresses.first.id, evidence: "isolated test route")
    address = session.add_address(box.id, address: "alias@#{key}.example.com")
    session.activate_address!(address.id, evidence: "isolated test alias")
  end
end

class MailboxIngressIntegrationTest < Minitest::Test
  include Rack::Test::Methods
  Email = Cloudflare::Email
  def app = Rails.application

  def setup
    CaptureMailbox.captures = []
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    %w[alpha beta].each do |key|
      Email::Mailboxes.for_tenant(key) do |session|
        Email::Mailboxes::Message.delete_all
        ActionMailbox::InboundEmail.destroy_all
        session.mailboxes.update_all(state: "active")
      end
    end
  end

  def raw
    "From: sender@example.net\r\nTo: misleading@example.net\r\nSubject: Tenant mail\r\nMessage-ID: <tenant-mail@example.net>\r\n\r\nhello\r\n"
  end

  def post_mail(recipient, valid: true)
    envelope = Email::Envelope.encode(from: "sender@example.net", to: recipient)
    timestamp = Time.now.to_i.to_s
    signature = Email::Verification.sign(secret: valid ? "test-ingress-secret" : "other",
      body: raw, timestamp: timestamp, envelope: envelope)
    post "/rails/action_mailbox/cloudflare/inbound_emails", raw,
      "CONTENT_TYPE" => "message/rfc822", "HTTP_X_CF_EMAIL_TIMESTAMP" => timestamp,
      "HTTP_X_CF_EMAIL_SIGNATURE" => signature, "HTTP_X_CF_EMAIL_SIGNATURE_VERSION" => "2",
      "HTTP_X_CF_EMAIL_ENVELOPE" => envelope
  end

  def test_signed_envelope_selects_storage_before_jobs_and_preserves_bytes
    %w[alpha beta].each do |key|
      post_mail("support@#{key}.example.com")
      assert_equal 200, last_response.status
      Email::Mailboxes.for_tenant(key) do
        assert_equal 1, Email::Mailboxes::Message.count
        inbound = ActionMailbox::InboundEmail.last
        assert_equal raw, inbound.raw_email.download
        assert_equal "support@#{key}.example.com", Email::Envelope.for(inbound).fetch("to")
      end
    end
    assert_nil Email::Tenancy.current_key
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == ActionMailbox::RoutingJob }
    assert_equal 2, jobs.size
    jobs.reverse_each { |job| ActiveJob::Base.execute(job) }
    assert_equal %w[beta alpha], CaptureMailbox.captures.map(&:first)
    assert CaptureMailbox.captures.all? { |capture| capture.last == raw }
    assert_nil Email::Tenancy.current_key
  end

  def test_duplicate_and_alias_membership_are_recipient_scoped
    2.times { post_mail("support@alpha.example.com"); assert_equal 200, last_response.status }
    post_mail("alias@alpha.example.com")
    assert_equal 200, last_response.status
    Email::Mailboxes.for_tenant("alpha") do
      assert_equal 2, ActionMailbox::InboundEmail.count
      assert_equal 2, Email::Mailboxes::Message.count
    end
    Email::Mailboxes.for_tenant("beta") { assert_equal 0, Email::Mailboxes::Message.count }
  end

  def test_unknown_suspended_and_unsigned_destinations_store_nothing
    post_mail("support@unknown.example.com")
    assert_equal 422, last_response.status
    post_mail("missing@alpha.example.com")
    assert_equal 422, last_response.status
    post_mail("support@alpha.example.com", valid: false)
    assert_equal 401, last_response.status
    Email::Mailboxes.for_tenant("alpha") { |session| session.suspend(session.mailboxes.first.id) }
    post_mail("support@alpha.example.com")
    assert_equal 422, last_response.status
    Email::Mailboxes.for_tenant("alpha") { assert_equal 0, ActionMailbox::InboundEmail.count }
    assert_nil Email::Tenancy.current_key
  end

  def test_membership_retains_raw_mail_until_explicit_purge
    post_mail("support@alpha.example.com")
    assert_equal 200, last_response.status
    Email::Mailboxes.for_tenant("alpha") do |session|
      membership = session.messages(session.mailboxes.first.id).first
      inbound = session.inbound_email(membership.mailbox_id, membership.id)
      inbound.update!(status: :delivered)
      inbound.update_columns(updated_at: 1.year.ago)
      inbound.incinerate
      assert_equal raw, inbound.reload.raw_email.download
      session.purge_message(membership.mailbox_id, membership.id)
      assert_equal 0, ActionMailbox::InboundEmail.count
      assert_equal 0, Email::Mailboxes::Message.count
    end
  end
end
