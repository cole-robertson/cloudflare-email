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
require "cloudflare/email/mailboxes"
require "cloudflare/email/management"
require "rack/test"
require "nokogiri"

MANAGEMENT_ROOT = Dir.mktmpdir("cf-email-management")
ENV["RAILS_ENV"] = "test"
ENV["DATABASE_URL"] = "sqlite3:#{MANAGEMENT_ROOT}/test.sqlite3"
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
  mount Cloudflare::Email::Management::Engine => "/nested/email"
end

class ManagementFixtureAdapter < Cloudflare::Email::Management::Adapter
  class_attribute :denied_actions, default: []
  class_attribute :permitted_domains, default: ["example.test"]
  class_attribute :unscoped_mailboxes, default: false

  def initialize(controller)
    @controller = controller
  end

  def authenticate! = @controller.session[:owner] == "owner-1"
  def tenant_key = "workspace"
  def mailboxes(session)
    scope = self.class.unscoped_mailboxes ? Cloudflare::Email::Mailboxes::Mailbox.all : session.mailboxes
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
%w[outbox/templates/create_cloudflare_email_outbox tracking/templates/create_cloudflare_email_event_receipts
   mailboxes/templates/create_cloudflare_email_receiving_domains mailboxes/templates/create_cloudflare_email_mailboxes
   mailboxes/templates/create_cloudflare_email_shared_events].each { |path| require "generators/cloudflare/email/#{path}" }
[CreateActiveStorageTables, CreateActionMailboxTables, CreateCloudflareEmailOutbox,
 CreateCloudflareEmailEventReceipts, CreateCloudflareEmailReceivingDomains,
 CreateCloudflareEmailSharedEvents, CreateCloudflareEmailMailboxes].each { |migration| migration.new.migrate(:up) }

class ManagementEngineIntegrationTest < Minitest::Test
  include Rack::Test::Methods
  Email = Cloudflare::Email
  PREFIX = "/nested/email"
  def app = Rails.application

  def setup
    clear_cookies
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
