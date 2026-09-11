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

CUSTOM_INGRESS_ROOT = Dir.mktmpdir("cf-tenant-ingress")
ENV["RAILS_ENV"] = "test"
ENV["DATABASE_URL"] = "sqlite3:#{CUSTOM_INGRESS_ROOT}/directory.sqlite3"
ENV["CLOUDFLARE_INGRESS_SECRET"] = "test-ingress-secret"
Minitest.after_run do
  ActiveRecord::Base.connection_handler.clear_all_connections!
  FileUtils.remove_entry(CUSTOM_INGRESS_ROOT)
end

class MailboxDirectoryRecord < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "sqlite3", database: "#{CUSTOM_INGRESS_ROOT}/directory.sqlite3")
end
class MailboxTenantRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to shards: %i[alpha beta].to_h { |key|
    [key, { writing: { adapter: "sqlite3", database: "#{CUSTOM_INGRESS_ROOT}/#{key}.sqlite3" } }]
  }
end
Cloudflare::Email::Tenancy.configure(base_class: MailboxTenantRecord,
  switch: ->(key, &block) { MailboxTenantRecord.connected_to(role: :writing, shard: key.to_sym, &block) },
  current: -> { MailboxTenantRecord.current_shard.to_s })
Cloudflare::Email::Mailboxes.configure(directory_base: MailboxDirectoryRecord)
require "cloudflare/email/mailboxes"
require "cloudflare/email/verification"
require "cloudflare/email/ingress"
require "cloudflare/email/provider_metadata"

# This fixture host uses Rails shards for framework records as well as gem
# records. Production hosts must configure their tenancy adapter equivalently.
module MailboxFrameworkConnection
  def connection_pool
    Cloudflare::Email::Tenancy.require_context!
    MailboxTenantRecord.connection_pool
  end
end

class CustomIngressApp < Rails::Application
  config.root = CUSTOM_INGRESS_ROOT
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
    local: {service: "Disk", root: "#{CUSTOM_INGRESS_ROOT}/blobs"}
  }
  config.to_prepare do
    ActionMailbox::Record.singleton_class.prepend(MailboxFrameworkConnection)
    ActiveStorage::Record.singleton_class.prepend(MailboxFrameworkConnection)
  end
end
CustomIngressApp.initialize!

class ApplicationMailbox < ActionMailbox::Base
  routing all: :capture
end
class CaptureMailbox < ApplicationMailbox
  class_attribute :captures, default: []
  def process
    self.class.captures += [[Cloudflare::Email::Tenancy.require_context!, inbound_email.id,
      mail.subject, inbound_email.raw_email.download, Cloudflare::Email::ProviderMetadata.for(inbound_email)]]
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
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: "#{CUSTOM_INGRESS_ROOT}/#{key}.sqlite3")
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


# The host owns HTTP status codes and review policy. It verifies before looking
# up a tenant, and checks policy inside that tenant before storing raw mail.
class CustomEmailController < ActionController::API
  def create
    result = Cloudflare::Email::Ingress.verify(
      secret: ENV.fetch("CLOUDFLARE_INGRESS_SECRET"),
      headers: request.headers, body: request.body,
      content_length: request.content_length, max_email_bytes: 1024 * 1024)
    return head(:unauthorized) unless result.status == :ok

    verified = result.message
    held = false
    Cloudflare::Email::Mailboxes.receive(recipient: verified.envelope.fetch("to")) do
      # Synthetic host policy; no claim that this is a provider SPF/DMARC API.
      if verified.provider_metadata&.dig("data", "host_review") == true
        held = true
        next nil
      end
      verified.persist_action_mailbox!
    end
    head(held ? :accepted : :created)
  rescue Cloudflare::Email::Mailboxes::Unavailable
    head :unprocessable_entity
  end
end
Rails.application.routes.draw { post "/custom-email", to: "custom_email#create" }

class CustomIngressIntegrationTest < Minitest::Test
  include Rack::Test::Methods
  Email = Cloudflare::Email
  def app = Rails.application

  def setup
    CaptureMailbox.captures = []
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    %w[alpha beta].each do |key|
      Email::Mailboxes.for_tenant(key) do
        Email::Mailboxes::Message.delete_all
        ActionMailbox::InboundEmail.destroy_all
        ActiveStorage::Blob.delete_all
      end
    end
  end

  def raw
    "From: sender@example.net\r\nTo: misleading@example.net\r\nSubject: Custom pipeline\r\nMessage-ID: <custom@example.net>\r\nContent-Transfer-Encoding: binary\r\n\r\n".b + "\x00\xff\xfe".b
  end

  def post_mail(recipient, metadata: nil, version: nil, signature_valid: true)
    version ||= metadata ? "3" : "2"
    envelope = Email::Envelope.encode(from: "sender@example.net", to: recipient)
    encoded = metadata && Email::Signing.base64url_encode(JSON.generate(metadata))
    timestamp = Time.now.to_i.to_s
    prefix = version == "3" ? "v3.#{timestamp}.#{envelope}.#{encoded}." : "v2.#{timestamp}.#{envelope}."
    signature = Email::Signing.hmac_hex(signature_valid ? "test-ingress-secret" : "wrong", prefix.b + raw)
    headers = {
      "CONTENT_TYPE" => "message/rfc822",
      "HTTP_X_CF_EMAIL_TIMESTAMP" => timestamp,
      "HTTP_X_CF_EMAIL_SIGNATURE" => signature,
      "HTTP_X_CF_EMAIL_SIGNATURE_VERSION" => version,
      "HTTP_X_CF_EMAIL_ENVELOPE" => envelope
    }
    headers["HTTP_X_CF_EMAIL_METADATA"] = encoded if encoded
    post "/custom-email", raw, headers
  end

  def metadata
    { "source" => "cloudflare", "data" => { "archive_key" => "synthetic/archive.eml" } }
  end

  def test_custom_controller_stores_metadata_before_tenant_routing_jobs
    %w[alpha beta].each do |tenant|
      post_mail("support@#{tenant}.example.com", metadata: metadata)
      assert_equal 201, last_response.status
      Email::Mailboxes.for_tenant(tenant) do
        assert_equal 1, Email::Mailboxes::Message.count
        inbound = ActionMailbox::InboundEmail.last
        assert_equal raw, inbound.raw_email.download
        assert_equal metadata, Email::ProviderMetadata.for(inbound)
        assert_equal "support@#{tenant}.example.com", Email::Envelope.for(inbound).fetch("to")
      end
    end
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == ActionMailbox::RoutingJob }
    assert_equal 2, jobs.size
    jobs.reverse_each { |job| ActiveJob::Base.execute(job) }
    assert_equal %w[beta alpha], CaptureMailbox.captures.map(&:first)
    assert CaptureMailbox.captures.all? { |capture| capture[3] == raw && capture[4] == metadata }
    assert_nil Email::Tenancy.current_key
  end

  def test_host_review_policy_can_stop_raw_storage_and_processing
    post_mail("support@alpha.example.com", metadata: { "source" => "cloudflare", "data" => { "host_review" => true } })
    assert_equal 202, last_response.status
    Email::Mailboxes.for_tenant("alpha") do
      assert_equal 0, ActionMailbox::InboundEmail.count
      assert_equal 0, Email::Mailboxes::Message.count
      assert_equal 0, ActiveStorage::Blob.count
    end
    assert_empty ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == ActionMailbox::RoutingJob }
  end

  def test_unsigned_metadata_and_unregistered_addresses_never_persist
    post_mail("support@alpha.example.com", metadata: metadata, version: "2")
    assert_equal 401, last_response.status
    post_mail("support@alpha.example.com", metadata: metadata, signature_valid: false)
    assert_equal 401, last_response.status
    post_mail("unknown@alpha.example.com", metadata: metadata)
    assert_equal 422, last_response.status
    %w[alpha beta].each do |tenant|
      Email::Mailboxes.for_tenant(tenant) { assert_equal 0, ActionMailbox::InboundEmail.count }
    end
    assert_nil Email::Tenancy.current_key
  end

  def test_binary_retries_are_idempotent_but_alias_and_metadata_context_are_distinct
    2.times do
      post_mail("support@alpha.example.com", metadata: metadata)
      assert_equal 201, last_response.status
    end
    post_mail("alias@alpha.example.com", metadata: metadata)
    assert_equal 201, last_response.status
    post_mail("support@alpha.example.com", metadata: { "source" => "cloudflare", "data" => { "archive_key" => "other.eml" } })
    assert_equal 201, last_response.status
    Email::Mailboxes.for_tenant("alpha") do
      assert_equal 3, ActionMailbox::InboundEmail.count
      assert_equal 3, Email::Mailboxes::Message.count
      assert ActionMailbox::InboundEmail.all.all? { |inbound| inbound.raw_email.download == raw }
    end
  end

  def test_v2_custom_ingress_remains_available_without_metadata
    2.times { post_mail("support@alpha.example.com"); assert_equal 201, last_response.status }
    Email::Mailboxes.for_tenant("alpha") do
      assert_equal 1, ActionMailbox::InboundEmail.count
      assert_nil Email::ProviderMetadata.for(ActionMailbox::InboundEmail.last)
    end
  end
end
