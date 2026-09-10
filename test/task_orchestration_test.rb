require "test_helper"
require "rails"
require "tmpdir"
require "stringio"
require "cloudflare/email/deploy_worker_task"
require "cloudflare/email/provision_route_task"
require "cloudflare/email/provision_catchall_task"
require "cloudflare/email/consume_events_task"

class TaskOrchestrationTest < Minitest::Test
  API = "https://api.cloudflare.com/client/v4"

  def setup
    @io = StringIO.new
    @credentials = { account_id: ACCOUNT_ID, api_token: "runtime-token", management_token: "management-token",
      ingress_secret: "synthetic-ingress-secret", queues_token: "queues-token", event_queue_id: "events" }
    @previous_env = Rails.env
    Rails.env = "staging"
  end

  def teardown
    Rails.env = @previous_env
    super
  end

  def with_credentials(&block)
    Cloudflare::Email::Credentials.stub(:fetch, ->(key) { @credentials.fetch(key, "") }, &block)
  end

  def success(result = {})
    { status: 200, body: JSON.generate("success" => true, "result" => result) }
  end

  def management_request(method, path)
    stub_request(method, "#{API}#{path}").with(headers: { "Authorization" => "Bearer management-token" })
  end

  def script_path
    "/accounts/#{ACCOUNT_ID}/workers/scripts/cloudflare-email-ingress-staging"
  end

  def deploy(**options)
    Dir.mktmpdir do |root|
      source = File.join(root, "worker.js")
      File.write(source, "export default { email() {} }")
      with_credentials { Cloudflare::Email::DeployWorkerTask.call(script_path: source, io: @io, **options) }
    end
  end

  def test_deploy_uploads_then_sets_secrets_with_management_token_and_environment
    calls = []
    management_request(:put, script_path).to_return { calls << :upload; success }
    management_request(:put, "#{script_path}/secrets").to_return do |request|
      calls << JSON.parse(request.body)
      success
    end
    assert_equal 0, deploy(ingress_url: "https://app.example.test/ingress")
    assert_equal [:upload,
      { "name" => "INGRESS_SECRET", "text" => "synthetic-ingress-secret", "type" => "secret_text" },
      { "name" => "RAILS_INGRESS_URL", "text" => "https://app.example.test/ingress", "type" => "secret_text" }], calls
    assert_includes @io.string, "cloudflare-email-ingress-staging"
  end

  def test_upload_failure_stops_before_any_secret_update
    management_request(:put, script_path).to_return(status: 403, body: cloudflare_error_body("Forbidden").to_json)
    assert_equal 1, deploy
    assert_not_requested :put, "#{API}#{script_path}/secrets"
    refute_includes @io.string, "script deployed"
  end

  def test_first_secret_failure_stops_before_ingress_url_update
    management_request(:put, script_path).to_return(success)
    secret = management_request(:put, "#{script_path}/secrets").with { |r| JSON.parse(r.body)["name"] == "INGRESS_SECRET" }
      .to_return(status: 403, body: cloudflare_error_body("Secret denied").to_json)
    assert_equal 1, deploy(ingress_url: "https://app.example.test/ingress")
    assert_requested secret, times: 1
    assert_requested :put, "#{API}#{script_path}/secrets", times: 1
    refute_includes @io.string, "RAILS_INGRESS_URL set"
  end

  def test_missing_credentials_or_source_fail_without_requests
    %i[account_id ingress_secret].each do |key|
      previous = @credentials.delete(key)
      assert_equal 1, deploy
      @credentials[key] = previous
    end
    with_credentials do
      assert_equal 1, Cloudflare::Email::DeployWorkerTask.call(script_path: "/missing-synthetic-worker.js", io: @io)
    end
    assert_not_requested :any, %r{api.cloudflare.com}
  end

  def prepare_zone(enabled: true)
    management_request(:get, "/zones?name=example.test").to_return(success([{ "id" => "zone", "name" => "example.test" }]))
    management_request(:get, "/zones/zone/email/routing").to_return(success("enabled" => enabled))
  end

  def test_route_task_selects_environment_worker_and_management_credentials
    prepare_zone
    management_request(:get, "/zones/zone/email/routing/rules?per_page=50&page=1").to_return(success([]))
    rule = management_request(:post, "/zones/zone/email/routing/rules").with do |request|
      body = JSON.parse(request.body)
      body["actions"] == [{ "type" => "worker", "value" => ["cloudflare-email-ingress-staging"] }] &&
        body["matchers"] == [{ "field" => "to", "type" => "literal", "value" => "inbox@example.test" }]
    end.to_return(success)
    with_credentials { assert_equal 0, Cloudflare::Email::ProvisionRouteTask.call(address: "inbox@example.test", io: @io) }
    assert_requested rule
  end

  def test_route_enable_failure_does_not_create_rule_or_report_success
    prepare_zone(enabled: false)
    management_request(:post, "/zones/zone/email/routing/dns").to_return(status: 403, body: cloudflare_error_body("DNS denied").to_json)
    with_credentials { assert_equal 1, Cloudflare::Email::ProvisionRouteTask.call(address: "inbox@example.test", io: @io) }
    assert_not_requested :post, "#{API}/zones/zone/email/routing/rules"
    refute_includes @io.string, "Route created/updated"
  end

  def test_catchall_task_honors_explicit_worker
    prepare_zone
    rule = management_request(:put, "/zones/zone/email/routing/rules/catch_all").with do |request|
      JSON.parse(request.body)["actions"] == [{ "type" => "worker", "value" => ["custom-worker"] }]
    end.to_return(success)
    with_credentials do
      assert_equal 0, Cloudflare::Email::ProvisionCatchallTask.call(domain: "example.test", worker_name: "custom-worker", io: @io)
    end
    assert_requested rule
  end

  def test_catchall_task_refuses_parent_zone_mutation_for_subdomain
    management_request(:get, "/zones?name=in.example.test").to_return(success([]))
    management_request(:get, "/zones?name=example.test").to_return(success([{ "id" => "zone", "name" => "example.test" }]))
    with_credentials { assert_equal 1, Cloudflare::Email::ProvisionCatchallTask.call(domain: "in.example.test", io: @io) }
    assert_not_requested :put, %r{/email/routing/}
    assert_not_requested :post, %r{/email/routing/}
  end

  def test_missing_routing_inputs_fail_without_requests
    with_credentials do
      assert_equal 1, Cloudflare::Email::ProvisionRouteTask.call(address: nil, io: @io)
      assert_equal 1, Cloudflare::Email::ProvisionCatchallTask.call(domain: nil, io: @io)
    end
    assert_not_requested :any, %r{api.cloudflare.com}
  end

  def test_events_task_reports_pull_failure_using_only_queue_credentials
    pull = stub_request(:post, "#{API}/accounts/#{ACCOUNT_ID}/queues/events/messages/pull")
      .with(headers: { "Authorization" => "Bearer queues-token" })
      .to_return(status: 403, body: cloudflare_error_body("Queue denied").to_json)
    with_credentials do
      assert_equal 1, Cloudflare::Email::ConsumeEventsTask.call(handler: ->(_) { flunk "failed pull yielded" }, io: @io)
    end
    assert_requested pull, times: 1
    assert_not_requested :post, %r{/messages/ack}
    refute_includes @io.string, "Processed and acknowledged"
  end

  def test_events_task_does_not_fall_back_to_runtime_token
    @credentials.delete(:queues_token)
    with_credentials do
      assert_equal 1, Cloudflare::Email::ConsumeEventsTask.call(handler: ->(_) {}, io: @io)
    end
    assert_not_requested :any, %r{api.cloudflare.com}
    assert_includes @io.string, "queues_token"
  end

  def test_event_handler_and_ack_failures_return_nonzero_without_claiming_success
    event = { "type" => "cf.email.sending.message.delivered", "source" => { "type" => "email.sending", "domain" => "example.test" },
      "payload" => { "eventId" => "event", "messageId" => "message", "terminal" => true },
      "metadata" => { "accountId" => ACCOUNT_ID, "eventSchemaVersion" => 1 } }
    pull_url = "#{API}/accounts/#{ACCOUNT_ID}/queues/events/messages/pull"
    ack_url = "#{API}/accounts/#{ACCOUNT_ID}/queues/events/messages/ack"
    [:handler, :ack].each do |failure|
      WebMock.reset!
      @io = StringIO.new
      stub_request(:post, pull_url).with(headers: { "Authorization" => "Bearer queues-token" }).to_return(success(
        "messages" => [{ "lease_id" => "lease", "body" => event.to_json, "metadata" => { "CF-Content-Type" => "text" } }]))
      stub_request(:post, ack_url).to_return(status: 503, body: cloudflare_error_body("Ack unavailable").to_json) if failure == :ack
      handled = 0
      handler = ->(_) { handled += 1; raise "Persistence failed" if failure == :handler }
      with_credentials { assert_equal 1, Cloudflare::Email::ConsumeEventsTask.call(handler: handler, io: @io) }
      assert_equal 1, handled
      assert_requested :post, pull_url, times: 1
      if failure == :handler
        assert_not_requested :post, ack_url
      else
        assert_requested :post, ack_url, times: 1
      end
      refute_includes @io.string, "Processed and acknowledged"
    end
  end
end
