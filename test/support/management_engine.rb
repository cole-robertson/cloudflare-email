if ENV["MAILBOX_KIT_ONLY"]
  require "minitest/autorun"
else
  require_relative "../test_helper"
end
require "tmpdir"
require "fileutils"
require "mailbox_kit/mailboxes" if ENV["MAILBOX_KIT_BEFORE_RAILS"]
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "active_job/railtie"
require "active_storage/engine"
require "action_mailbox/engine"
if ENV["MAILBOX_KIT_ONLY"]
  require "mailbox_kit/mailboxes"
  require "mailbox_kit/management"
  if ENV["MAILBOX_KIT_ISOLATED"]
    abort "isolated core consumer includes Cloudflare" if defined?(Cloudflare) || Gem.loaded_specs.key?("cloudflare-email")
  end
  if ENV["MAILBOX_KIT_EXPECTED_ROOT"]
    abort "core loaded from source" unless MailboxKit::ROOT == ENV.fetch("MAILBOX_KIT_EXPECTED_ROOT")
  end
  FixtureEmail = MailboxKit
else
  require "cloudflare/email/mailboxes"
  require "cloudflare/email/management"
  FixtureEmail = Cloudflare::Email
end
require "rack/test"
require "nokogiri"
require "minitest/mock"

MANAGEMENT_ROOT = Dir.mktmpdir("cf-email-management")
ENV["RAILS_ENV"] = "test"
ENV["DATABASE_URL"] = ENV.fetch("MAILBOX_KIT_POSTGRES_URL", "sqlite3:#{MANAGEMENT_ROOT}/test.sqlite3")
Minitest.after_run do
  ActiveRecord::Base.connection_handler.clear_all_connections!
  FileUtils.remove_entry(MANAGEMENT_ROOT)
end

class ManagementFixtureApp < Rails::Application
  config.root = MANAGEMENT_ROOT
  config.eager_load = false
  config.enable_reloading = false
  config.secret_key_base = "m" * 64
  config.hosts.clear
  config.logger = Logger.new(File::NULL)
  config.action_dispatch.show_exceptions = :rescuable
  config.action_controller.allow_forgery_protection = true
  config.active_job.queue_adapter = :test
  config.active_storage.service = :local
  config.active_storage.service_configurations = {
    local: { service: "Disk", root: "#{MANAGEMENT_ROOT}/blobs" }
  }
end
ManagementFixtureApp.initialize!

class ManagementFixtureLoginController < ActionController::Base
  # Synthetic local harness only: provides a real cookie-backed host session.
  def create
    session[:owner] = "owner-1"
    head :ok
  end
end
Rails.application.routes.draw do
  post "/fixture-login", to: "management_fixture_login#create"
  post "/rails/action_mailbox/postmark/inbound_emails", to: "action_mailbox/ingresses/postmark/inbound_emails#create"
  mount FixtureEmail::Management::Engine => "/nested/email"
end

class ManagementFixtureAdapter < FixtureEmail::Management::Adapter
  class_attribute :denied_actions, default: []
  class_attribute :permitted_domains, default: ["example.test"]
  class_attribute :unscoped_mailboxes, default: false

  def initialize(controller)
    @controller = controller
  end

  def authenticate! = @controller.session[:owner] == "owner-1"
  def tenant_key = "workspace"
  def mailboxes(session)
    scope = self.class.unscoped_mailboxes ? FixtureEmail::Mailboxes::Mailbox.all : session.mailboxes
    scope.where(owner_ref: @controller.session[:owner])
  end
  def allowed?(action, mailbox = nil) = !self.class.denied_actions.include?(action.to_sym)
  def domains(session) = self.class.permitted_domains

  def create_mailbox(session, name:, address:)
    session.create(name: name, address: address, owner_ref: @controller.session[:owner])
  end
end

class ManagementWrongOwnerAdapter < ManagementFixtureAdapter
  def create_mailbox(session, name:, address:)
    session.create(name: name, address: address, owner_ref: "owner-2")
  end
end

class ManagementInvalidTenantAdapter < ManagementFixtureAdapter
  def tenant_key = nil
end

ActiveRecord::Migration.verbose = false
%w[activestorage actionmailbox].each do |name|
  Dir["#{Gem.loaded_specs.fetch(name).full_gem_path}/db/migrate/*.rb"].each { |path| require path }
end
if ENV["MAILBOX_KIT_ONLY"]
  require "generators/mailbox_kit/install/templates/create_mailbox_kit_receiving_domains"
  require "generators/mailbox_kit/install/templates/create_mailbox_kit_mailboxes"
  [CreateActiveStorageTables, CreateActionMailboxTables, CreateMailboxKitReceivingDomains,
   CreateMailboxKitMailboxes].each { |migration| migration.new.migrate(:up) }
  abort "core loaded Cloudflare adapter" if $LOADED_FEATURES.any? { |path| path.end_with?("/cloudflare-email.rb", "/cloudflare/email/client.rb") }
else
%w[outbox/templates/create_cloudflare_email_outbox tracking/templates/create_cloudflare_email_event_receipts
   mailboxes/templates/create_cloudflare_email_receiving_domains mailboxes/templates/create_cloudflare_email_mailboxes
   mailboxes/templates/create_cloudflare_email_shared_events].each { |path| require "generators/cloudflare/email/#{path}" }
[CreateActiveStorageTables, CreateActionMailboxTables, CreateCloudflareEmailOutbox,
 CreateCloudflareEmailEventReceipts, CreateCloudflareEmailReceivingDomains,
 CreateCloudflareEmailSharedEvents, CreateCloudflareEmailMailboxes].each { |migration| migration.new.migrate(:up) }
end

class ManagementEngineIntegrationTest < Minitest::Test
  include Rack::Test::Methods
  Email = FixtureEmail
  PREFIX = "/nested/email"
  def app = Rails.application

  def setup
    clear_cookies
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    ManagementFixtureAdapter.denied_actions = []
    ManagementFixtureAdapter.permitted_domains = ["example.test"]
    ManagementFixtureAdapter.unscoped_mailboxes = false
    Email::Management.configure { |config| config.adapter = ->(controller) { ManagementFixtureAdapter.new(controller) } }
    ActiveRecord::Base.connection.disable_referential_integrity do
      ActiveRecord::Base.connection.tables.each do |table|
        next if %w[schema_migrations ar_internal_metadata].include?(table)
        ActiveRecord::Base.connection.execute("DELETE FROM #{ActiveRecord::Base.connection.quote_table_name(table)}")
      end
    end
    %w[example.test hidden.test].each do |name|
      domain = Email::Mailboxes.register_domain(domain: name, tenant_key: "workspace", account_id: "synthetic-account")
      Email::Mailboxes.activate_domain!(domain.id, evidence: "local fixture")
    end
    domain = Email::Mailboxes.register_domain(domain: "other.test", tenant_key: "other", account_id: "synthetic-account")
    Email::Mailboxes.activate_domain!(domain.id, evidence: "local fixture")
    with_session do |session|
      @owned = session.create(name: "Owner inbox", address: "owner@example.test", owner_ref: "owner-1")
      @private = session.create(name: "Private owner inbox", address: "private@example.test", owner_ref: "owner-2")
    end
    Email::Mailboxes.for_tenant("other") do |session|
      @other = session.create(name: "Other tenant inbox", address: "box@other.test", owner_ref: "owner-1")
    end
    post "/fixture-login"
    assert_equal 200, last_response.status
  end

  def with_session(&block) = Email::Mailboxes.for_tenant("workspace", &block)
  def mailbox_path(mailbox = @owned) = "#{PREFIX}/mailboxes/#{mailbox.id}"

  def test_raw_mail_is_retained_until_explicit_purge
    member, inbound = incoming(@owned)
    with_session do |session|
      inbound.delivered!
      inbound.update_columns(updated_at: 60.days.ago)
      inbound.incinerate
      assert ActionMailbox::InboundEmail.exists?(inbound.id)
      transient = ActionMailbox::InboundEmail.create_and_extract_message_id!("Message-ID: <transient@example.test>\r\n\r\nTemporary")
      transient.delivered!
      transient.update_columns(updated_at: 60.days.ago)
      transient.incinerate
      refute ActionMailbox::InboundEmail.exists?(transient.id)
      session.purge_message(@owned.id, member.id)
      refute ActionMailbox::InboundEmail.exists?(inbound.id)
    end
  end

  def activate_addresses
    %w[workspace other].each do |key|
      Email::Mailboxes.for_tenant(key) do |session|
        session.mailboxes.each do |box|
          box.addresses.each { |address| session.activate_address!(address.id, evidence: "local routing verification") }
        end
      end
    end
  end

  def source_for_memberships
    "From: sender@example.test\r\nTo: misleading@example.test\r\nMessage-ID: <membership@example.test>\r\nSubject: Shared source\r\n\r\nHello\r\n"
  end

  def test_source_receiving_shares_rails_record_across_inboxes_without_reprocessing
    activate_addresses
    first = Email::Mailboxes.receive(recipient: "owner@example.test", source: source_for_memberships)
    with_session { |session| session.mark_read(@owned.id, session.messages(@owned.id).first.id) }
    second = Email::Mailboxes.receive(recipient: "private@example.test", source: source_for_memberships)
    replay = Email::Mailboxes.receive(recipient: "owner@example.test", source: source_for_memberships)
    assert_equal first.id, second.id
    assert_equal first.id, replay.id
    assert_equal source_for_memberships, first.source
    assert_equal 1, ActionMailbox::InboundEmail.count
    assert_equal 2, Email::Mailboxes::Message.count
    assert_equal 1, ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:job] == ActionMailbox::RoutingJob }
    with_session do |session|
      assert session.messages(@owned.id).first.read_at
      assert_nil session.messages(@private.id).first.read_at
      session.purge_message(@owned.id, session.messages(@owned.id).first.id)
      assert ActionMailbox::InboundEmail.exists?(first.id)
      session.purge_message(@private.id, session.messages(@private.id).first.id)
      refute ActionMailbox::InboundEmail.exists?(first.id)
    end
  end

  def test_source_receiving_separates_tenants_even_when_they_share_a_database
    activate_addresses
    first = Email::Mailboxes.receive(recipient: "owner@example.test", source: source_for_memberships)
    second = Email::Mailboxes.receive(recipient: "box@other.test", source: source_for_memberships)
    refute_equal first.id, second.id
    assert_equal 2, ActionMailbox::InboundEmail.count
    assert_equal 2, ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:job] == ActionMailbox::RoutingJob }
    Email::Mailboxes.for_tenant("other") do |session|
      assert_raises(Email::ConfigurationError) do
        session.attach(recipient: "box@other.test", inbound_email_id: first.id)
      end
    end
  end

  def test_existing_rails_records_attach_idempotently_and_reserve_suspended_addresses
    activate_addresses
    inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source_for_memberships)
    with_session do |session|
      entry = session.attach(recipient: "owner@example.test", inbound_email_id: inbound.id)
      replay = session.attach(recipient: "owner@example.test", inbound_email_id: inbound.id)
      assert_equal entry.id, replay.id
      alias_address = session.add_address(@owned.id, address: "alias@example.test")
      session.activate_address!(alias_address.id, evidence: "fixture")
      assert_equal entry.id, session.attach(recipient: alias_address.address, inbound_email_id: inbound.id).id
      session.suspend_address(@owned.id, alias_address.id)
      assert_raises(Email::Mailboxes::Unavailable) do
        session.attach(recipient: alias_address.address, inbound_email_id: inbound.id)
      end
      assert_raises(ActiveRecord::RecordNotFound) do
        session.attach(recipient: "owner@example.test", inbound_email_id: -1)
      end
      assert_raises(ActiveRecord::RecordNotFound) do
        session.attach(recipient: "box@other.test", inbound_email_id: inbound.id)
      end
    end
    assert_equal 1, Email::Mailboxes::Message.count
    assert_equal 1, ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:job] == ActionMailbox::RoutingJob }
  end

  def test_rails_retention_setting_disables_scheduling_without_kit_membership
    previous = ActionMailbox.incinerate
    ActionMailbox.incinerate = false
    inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source_for_memberships)
    inbound.delivered!
    assert inbound.persisted?
    assert_equal 0, Email::Mailboxes::Message.count
    refute ActiveJob::Base.queue_adapter.enqueued_jobs.any? { |job| job[:job] == ActionMailbox::IncinerationJob }
  ensure
    ActionMailbox.incinerate = previous
  end

  def test_missing_message_id_replay_is_stable_across_hosts
    activate_addresses
    source = "From: sender@example.test\r\n\r\nNo Message-ID"
    first = Socket.stub(:gethostname, "host-one") { Email::Mailboxes.receive(recipient: "owner@example.test", source: source) }
    second = Socket.stub(:gethostname, "host-two") { Email::Mailboxes.receive(recipient: "private@example.test", source: source) }
    assert_equal first.id, second.id
    assert_equal source, second.source
    assert_equal 2, Email::Mailboxes::Message.count
  end

  def test_failed_membership_rolls_back_rails_records_and_routing_enqueue
    activate_addresses
    failure = ->(*, **) { raise "membership write failed" }
    Email::Mailboxes::Message.stub(:create_or_find_by!, failure) do
      assert_raises(RuntimeError) do
        Email::Mailboxes.receive(recipient: "owner@example.test", source: source_for_memberships)
      end
    end
    assert_equal 0, ActionMailbox::InboundEmail.count
    assert_equal 0, ActiveStorage::Blob.count
    refute ActiveJob::Base.queue_adapter.enqueued_jobs.any? { |job| job[:job] == ActionMailbox::RoutingJob }
    assert_nil Email::Tenancy.current_key
  end

  def test_stock_postmark_ingress_can_feed_existing_record_attachment
    previous_ingress = ActionMailbox.ingress
    previous_password = ENV["RAILS_INBOUND_EMAIL_PASSWORD"]
    ActionMailbox.ingress = :postmark
    ENV["RAILS_INBOUND_EMAIL_PASSWORD"] = "local-postmark-password"
    activate_addresses
    headers = { "CONTENT_TYPE" => "application/json",
      "HTTP_AUTHORIZATION" => "Basic #{Base64.strict_encode64('actionmailbox:local-postmark-password')}" }
    payload = { RawEmail: source_for_memberships, OriginalRecipient: "owner@example.test" }.to_json
    2.times do
      post "/rails/action_mailbox/postmark/inbound_emails", payload, headers
      assert_equal 204, last_response.status
    end
    inbound = ActionMailbox::InboundEmail.sole
    # A fixed, host-authorized route in a single database: no inference of
    # tenant entitlement from MIME To or X-Original-To headers.
    with_session do |session|
      session.attach(recipient: "owner@example.test", inbound_email_id: inbound.id)
    end
    assert_equal inbound.id, Email::Mailboxes::Message.sole.inbound_email_id
    assert_equal 1, ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:job] == ActionMailbox::RoutingJob }
  ensure
    ActionMailbox.ingress = previous_ingress
    ENV["RAILS_INBOUND_EMAIL_PASSWORD"] = previous_password
  end

  if ENV["MAILBOX_KIT_POSTGRES_URL"]
    def test_concurrent_postgres_source_delivery_recovers_the_unique_conflict
      require "timeout"
      activate_addresses
      model = ActionMailbox::InboundEmail
      original = model.method(:create_and_extract_message_id!)
      entered, release = Queue.new, Queue.new
      barrier = ->(*args, **options) do
        entered << true
        Timeout.timeout(10) { release.pop }
        original.call(*args, **options)
      end
      workers = []
      model.stub(:create_and_extract_message_id!, barrier) do
        2.times do
          workers << Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              Email::Mailboxes.receive(recipient: "owner@example.test", source: source_for_memberships).id
            end
          end
        end
        2.times { Timeout.timeout(10) { entered.pop } }
        2.times { release << true }
        ids = workers.map { |worker| Timeout.timeout(10) { worker.value } }
        assert_equal 1, ids.uniq.length
      end
      assert_equal 1, ActionMailbox::InboundEmail.count
      assert_equal 1, Email::Mailboxes::Message.count
      assert_equal 1, ActiveStorage::Blob.count
      assert_equal 1, ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:job] == ActionMailbox::RoutingJob }
    ensure
      2.times { release << true } if release
      workers&.each { |worker| worker.join(12) || worker.kill }
    end
  end

  def test_framework_jobs_capture_context_and_allow_single_database_work
    with_session do
      payload = ActionMailbox::RoutingJob.new.serialize
      assert_equal "workspace", payload.fetch("cloudflare_email_tenant_key")
      assert_equal "workspace", ActiveStorage::PurgeJob.new.serialize.fetch("cloudflare_email_tenant_key")
    end
    refute ActionMailbox::RoutingJob.new.serialize.key?("cloudflare_email_tenant_key")
  end
  def html = Nokogiri::HTML(last_response.body)

  def token(path = "#{PREFIX}/mailboxes")
    get path
    assert_equal 200, last_response.status, last_response.body
    node = html.at_css('input[name="authenticity_token"]') || html.at_css('meta[name="csrf-token"]')
    refute_nil node, "rendered management form needs a CSRF token"
    node["value"] || node["content"]
  end

  def mutate(path, params = {}, source: mailbox_path)
    csrf = token(source)
    post path, params.merge(authenticity_token: csrf)
  end

  def test_opt_in_keeps_database_tenancy_disabled_and_scopes_index
    refute Email::Tenancy.enabled?
    get "#{PREFIX}/mailboxes"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Owner inbox"
    refute_includes last_response.body, "Private owner inbox"
    refute_includes last_response.body, "Other tenant inbox"
    html.css("form[action]").each { |form| assert form["action"].start_with?(PREFIX), form["action"] }
    assert_includes last_response.headers["cache-control"], "no-store"
    assert_includes last_response.headers["content-security-policy"], "frame-ancestors 'none'"
    assert_includes last_response.headers["content-security-policy"], "default-src 'none'"
    # Same-origin form requests need a usable Origin for Rails CSRF validation.
    # Cross-origin destinations still receive no mailbox URL in their Referer.
    assert_equal "same-origin", last_response.headers["referrer-policy"]
    assert_nil Email::Tenancy.current_key
    stylesheet = html.at_css('link[rel="stylesheet"]')["href"]
    assert stylesheet.start_with?(PREFIX), stylesheet
    get stylesheet
    assert_equal 200, last_response.status
    assert_includes last_response.headers["content-type"], "text/css"
    assert_includes last_response.body, ".shell"
  end

  def test_anonymous_unconfigured_and_default_adapters_fail_closed
    clear_cookies
    get "#{PREFIX}/mailboxes"
    assert_equal 401, last_response.status
    Email::Management.configure { |config| config.adapter = nil }
    get "#{PREFIX}/mailboxes"
    assert_equal 503, last_response.status
    Email::Management.configure { |config| config.adapter = ->(controller) { Email::Management::Adapter.new(controller) } }
    get "#{PREFIX}/mailboxes"
    assert_equal 401, last_response.status
  end

  def test_owner_and_tenant_boundaries
    [@private, @other].each do |box|
      get mailbox_path(box)
      assert_equal 404, last_response.status
      mutate "#{mailbox_path(box)}/suspend"
      assert_equal 404, last_response.status
      assert_equal "active", box.reload.state
    end
  end

  def test_invalid_host_tenant_configuration_returns_unavailable
    Email::Management.configure { |config| config.adapter = ->(controller) { ManagementInvalidTenantAdapter.new(controller) } }
    get "#{PREFIX}/mailboxes"
    assert_equal 503, last_response.status
    refute_includes last_response.body, "Owner inbox"
    assert_nil last_response.headers["location"]
    assert_nil Email::Tenancy.current_key
  end

  def test_custom_create_hook_cannot_leave_invisible_mailboxes_or_addresses
    csrf = token
    Email::Management.configure { |config| config.adapter = ->(controller) { ManagementWrongOwnerAdapter.new(controller) } }
    mailbox_count = Email::Mailboxes::Mailbox.count
    address_count = Email::Mailboxes::Address.count
    post "#{PREFIX}/mailboxes", authenticity_token: csrf, mailbox: { name: "Wrong owner", address: "wrong-owner@example.test" }
    assert_equal 404, last_response.status
    assert_equal mailbox_count, Email::Mailboxes::Mailbox.count
    assert_equal address_count, Email::Mailboxes::Address.count
    refute Email::Mailboxes::Mailbox.exists?(name: "Wrong owner")
    refute Email::Mailboxes::Address.exists?(address: "wrong-owner@example.test")
    assert_nil Email::Tenancy.current_key
  end

  def test_host_scope_cannot_accidentally_remove_tenant_filter
    ManagementFixtureAdapter.unscoped_mailboxes = true
    get "#{PREFIX}/mailboxes"
    assert_equal 200, last_response.status
    refute_includes last_response.body, "Other tenant inbox"
    get mailbox_path(@other)
    assert_equal 404, last_response.status
  end

  def test_permissions_block_reads_and_writes
    csrf = token
    ManagementFixtureAdapter.denied_actions = %i[index show create suspend]
    get "#{PREFIX}/mailboxes"
    assert_equal 403, last_response.status
    get mailbox_path
    assert_equal 403, last_response.status
    post "#{PREFIX}/mailboxes", authenticity_token: csrf, mailbox: { name: "Forbidden", address: "new@example.test" }
    assert_equal 403, last_response.status
    post "#{mailbox_path}/suspend", authenticity_token: csrf
    assert_equal 403, last_response.status
    assert_equal "active", @owned.reload.state
    with_session { |session| refute session.mailboxes.exists?(name: "Forbidden") }
  end

  def test_create_and_alias_are_pending_and_cannot_claim_disallowed_domains
    mutate "#{PREFIX}/mailboxes", { mailbox: { name: "New inbox", address: "new@example.test", owner_ref: "owner-2", tenant_key: "other" } }, source: "#{PREFIX}/mailboxes"
    assert_includes [302, 303], last_response.status
    with_session do |session|
      box = session.mailboxes.find_by!(name: "New inbox")
      assert_equal "owner-1", box.owner_ref
      assert_equal "workspace", box.tenant_key
      assert_equal "pending", session.addresses(box.id).first.state
    end
    mutate "#{mailbox_path}/aliases", { address: "alias@example.test" }
    assert_includes [302, 303], last_response.status
    with_session { |session| assert_equal "pending", session.addresses(@owned.id).find_by!(address: "alias@example.test").state }
    %w[hidden.test other.test unregistered.test].each do |domain|
      mutate "#{PREFIX}/mailboxes", { mailbox: { name: "Rejected", address: "new@#{domain}" } }, source: "#{PREFIX}/mailboxes"
      assert_includes [303, 403, 422], last_response.status
      mutate "#{mailbox_path}/aliases", { address: "alias@#{domain}" }
      assert_includes [303, 403, 422], last_response.status
    end
    with_session do |session|
      refute session.mailboxes.exists?(name: "Rejected")
      assert_equal 2, session.addresses(@owned.id).count
    end
    refute Email::Mailboxes::ReceivingDomain.exists?(domain: "unregistered.test")
  end

  def test_csrf_and_http_methods_protect_mutations
    post "#{mailbox_path}/suspend"
    assert_equal 422, last_response.status
    post "#{mailbox_path}/suspend", authenticity_token: "invalid"
    assert_equal 422, last_response.status
    get "#{mailbox_path}/suspend"
    assert_includes [404, 405], last_response.status
    assert_equal "active", @owned.reload.state
    csrf = token
    post "#{mailbox_path}/suspend", { authenticity_token: csrf }, "HTTP_ORIGIN" => "https://other.example"
    assert_equal 422, last_response.status
    assert_equal "active", @owned.reload.state
    post "#{mailbox_path}/suspend", { authenticity_token: csrf }, "HTTP_ORIGIN" => "http://example.org"
    assert_equal 303, last_response.status
    assert_equal "suspended", @owned.reload.state
  end

  def test_suspension_is_reversible_and_retains_membership_and_raw_mail
    member, inbound = incoming(@owned)
    mutate "#{mailbox_path}/suspend"
    assert_includes [302, 303], last_response.status
    assert_equal "suspended", @owned.reload.state
    assert Email::Mailboxes::Message.exists?(member.id)
    assert inbound.reload.raw_email.attached?
    mutate "#{mailbox_path}/resume"
    assert_includes [302, 303], last_response.status
    assert_equal "active", @owned.reload.state
  end

  def incoming(box, html_only: false)
    raw = "From: sender@example.test\r\nTo: owner@example.test\r\nSubject: Local fixture\r\nMessage-ID: <#{SecureRandom.uuid}@example.test>\r\nContent-Type: #{html_only ? 'text/html' : 'text/plain'}; charset=UTF-8\r\n\r\n<script>alert('fixture')</script><img src=\"https://remote.example/tracker\">\r\n"
    with_session do
      inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(raw)
      member = Email::Mailboxes::Message.create!(mailbox: box, tenant_key: "workspace", inbound_email_id: inbound.id, recipient: "owner@example.test")
      [member, inbound]
    end
  end

  def test_message_preview_escapes_content_and_scopes_membership
    member, = incoming(@owned)
    foreign, = incoming(@private)
    @owned.update!(name: "<script>unsafe name</script>")
    get mailbox_path
    assert_equal 200, last_response.status
    refute_includes last_response.body, "<script>unsafe name</script>"
    get "#{mailbox_path}/messages/#{member.id}"
    assert_equal 200, last_response.status
    assert_includes html.text, "alert('fixture')"
    assert_empty html.css('script, img[src^="https://remote.example"], iframe, object, embed')
    get "#{mailbox_path}/messages/#{foreign.id}"
    assert_equal 404, last_response.status
    mutate "#{mailbox_path}/mark_read", { message_id: foreign.id, read: "true" }
    assert_equal 404, last_response.status
    assert_nil foreign.reload.read_at
    mutate "#{mailbox_path}/archive", { message_id: foreign.id, archived: "true" }
    assert_equal 404, last_response.status
    assert_nil foreign.reload.archived_at
    mutate "#{mailbox_path}/mark_read", { message_id: member.id, read: "true" }
    assert_includes [302, 303], last_response.status
    refute_nil member.reload.read_at
    mutate "#{mailbox_path}/mark_read", { message_id: member.id, read: "false" }
    assert_includes [302, 303], last_response.status
    assert_nil member.reload.read_at
    mutate "#{mailbox_path}/archive", { message_id: member.id, archived: "true" }
    assert_includes [302, 303], last_response.status
    refute_nil member.reload.archived_at
    mutate "#{mailbox_path}/archive", { message_id: member.id, archived: "false" }
    assert_includes [302, 303], last_response.status
    assert_nil member.reload.archived_at
    assert ActionMailbox::InboundEmail.exists?(member.inbound_email_id)
  end

  def test_html_only_mail_never_embeds_sender_html
    member, = incoming(@owned, html_only: true)
    get "#{mailbox_path}/messages/#{member.id}"
    assert_equal 200, last_response.status
    assert_empty html.css('script, img, iframe, object, embed')
  end

  def test_each_message_and_alias_operation_requires_permission
    member, = incoming(@owned)
    csrf = token
    ManagementFixtureAdapter.denied_actions = %i[show_message mark_read archive add_address resume]
    get "#{mailbox_path}/messages/#{member.id}"
    assert_equal 403, last_response.status
    %w[mark_read archive].each do |action|
      post "#{mailbox_path}/#{action}", authenticity_token: csrf, message_id: member.id
      assert_equal 403, last_response.status
    end
    post "#{mailbox_path}/aliases", authenticity_token: csrf, address: "forbidden@example.test"
    assert_equal 403, last_response.status
    @owned.update!(state: "suspended")
    post "#{mailbox_path}/resume", authenticity_token: csrf
    assert_equal 403, last_response.status
    assert_equal "suspended", @owned.reload.state
    assert_nil member.reload.read_at
    assert_nil member.archived_at
    with_session { |session| assert_equal 1, session.addresses(@owned.id).count }
  end

  def test_invalid_pagination_and_boolean_inputs_do_not_mutate_or_raise
    ["-1", "no-number", "9" * 50].each do |cursor|
      get "#{PREFIX}/mailboxes", after: cursor
      assert_includes [303, 422], last_response.status
    end
    member, = incoming(@owned)
    mutate "#{mailbox_path}/mark_read", { message_id: member.id, read: "unexpected" }
    assert_includes [303, 422], last_response.status
    assert_nil member.reload.read_at
    mutate "#{mailbox_path}/archive", { message_id: member.id, archived: "unexpected" }
    assert_includes [303, 422], last_response.status
    assert_nil member.reload.archived_at
  end

  def test_malformed_mailbox_parameter_shapes_do_not_create_records_or_raise
    mailbox_count = Email::Mailboxes::Mailbox.count
    address_count = Email::Mailboxes::Address.count
    ["scalar", ["array"]].each do |value|
      mutate "#{PREFIX}/mailboxes", { mailbox: value }, source: "#{PREFIX}/mailboxes"
      assert_equal 303, last_response.status
      assert_equal mailbox_count, Email::Mailboxes::Mailbox.count
      assert_equal address_count, Email::Mailboxes::Address.count
    end
  end
end
