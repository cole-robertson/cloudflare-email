require "test_helper"
require "cloudflare/email/routing_provisioner"

class RoutingProvisionerTest < Minitest::Test
  TOKEN    = "cf-token".freeze
  ZONE_ID  = "zone-abc-123".freeze
  DOMAIN   = "in.example.com".freeze
  PARENT   = "example.com".freeze
  ADDRESS  = "cole@in.example.com".freeze
  WORKER   = "cloudflare-email-ingress-production".freeze

  def make
    Cloudflare::Email::RoutingProvisioner.new(api_token: TOKEN)
  end

  def test_requires_api_token
    assert_raises(ArgumentError) do
      Cloudflare::Email::RoutingProvisioner.new(api_token: "")
    end
  end

  def test_rejects_insecure_remote_api_endpoint_before_sending_credentials
    assert_raises(Cloudflare::Email::ConfigurationError) do
      Cloudflare::Email::RoutingProvisioner.new(api_token: TOKEN, api_base: "http://api.example.test/client/v4")
    end
    assert_not_requested :any, %r{api.example.test}
  end

  def test_expand_parent_domains
    p = make
    assert_equal ["a.b.example.com", "b.example.com", "example.com"],
                 p.send(:expand_parent_domains, "a.b.example.com")
    assert_equal ["example.com"], p.send(:expand_parent_domains, "example.com")
  end

  def test_find_zone_id_walks_parent_domains
    # First query for in.example.com returns empty result
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones?name=in.example.com")
      .to_return(status: 200, body: JSON.generate("result" => []))
    # Then example.com returns our zone
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones?name=example.com")
      .to_return(status: 200, body: JSON.generate("result" => [{ "id" => ZONE_ID, "name" => PARENT }]))

    assert_equal ZONE_ID, make.find_zone_id_for(DOMAIN)
  end

  def test_find_zone_id_returns_nil_when_not_found
    stub_request(:get, %r{zones\?name=})
      .to_return(status: 200, body: JSON.generate("result" => []))

    assert_nil make.find_zone_id_for("unknown.example.net")
  end

  def test_enable_routing_skipped_when_already_enabled
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing")
      .to_return(status: 200, body: JSON.generate("result" => { "enabled" => true }))

    make.enable_routing_if_needed(ZONE_ID)

    assert_not_requested :post, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/dns"
  end

  def test_enable_routing_called_when_not_enabled
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing")
      .to_return(status: 200, body: JSON.generate("result" => { "enabled" => false }))
    stub = stub_request(:post, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/dns")
      .to_return(status: 200, body: JSON.generate("result" => { "enabled" => true }))

    make.enable_routing_if_needed(ZONE_ID)
    assert_requested(stub)
  end

  def test_settings_failures_are_not_ignored
    [403, 404].each do |status|
      stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing")
        .to_return(status: status, body: JSON.generate("errors" => [{ "message" => "Cannot read settings" }]))
      error = assert_raises(Cloudflare::Email::Error) { make.enable_routing_if_needed(ZONE_ID) }
      assert_equal status, error.status
    end
    WebMock.assert_not_requested(:post, %r{email/routing/dns})
  end

  def test_upsert_creates_rule_when_missing
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/rules?per_page=50&page=1")
      .to_return(status: 200, body: JSON.generate("result" => []))

    stub = stub_request(:post, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/rules")
      .with { |req|
        body = JSON.parse(req.body)
        assert_equal true, body["enabled"]
        assert_equal [{ "field" => "to", "type" => "literal", "value" => ADDRESS }], body["matchers"]
        assert_equal [{ "type" => "worker", "value" => [WORKER] }], body["actions"]
        true
      }
      .to_return(status: 200, body: JSON.generate("result" => { "id" => "rule-1" }))

    make.upsert_route(zone_id: ZONE_ID, address: ADDRESS, worker_name: WORKER)
    assert_requested(stub)
  end

  def test_upsert_updates_rule_when_existing
    existing = {
      "id"       => "rule-existing-1",
      "matchers" => [{ "field" => "to", "type" => "literal", "value" => ADDRESS }],
    }
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/rules?per_page=50&page=1")
      .to_return(status: 200, body: JSON.generate("result" => [existing]))

    stub = stub_request(:put, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/rules/rule-existing-1")
      .with { |req|
        body = JSON.parse(req.body)
        assert_equal [{ "type" => "worker", "value" => [WORKER] }], body["actions"]
        true
      }
      .to_return(status: 200, body: JSON.generate("result" => existing))

    make.upsert_route(zone_id: ZONE_ID, address: ADDRESS, worker_name: WORKER)
    assert_requested(stub)
  end

  def test_provision_end_to_end
    # 1. find zone
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones?name=in.example.com")
      .to_return(status: 200, body: JSON.generate("result" => []))
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones?name=example.com")
      .to_return(status: 200, body: JSON.generate("result" => [{ "id" => ZONE_ID }]))

    # 2. Check subdomain DNS without reading/enabling parent routing.
    stub_subdomain_dns

    # 3. list rules (empty)
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/rules?per_page=50&page=1")
      .to_return(status: 200, body: JSON.generate("result" => []))

    # 4. create rule
    create_stub = stub_request(:post, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/rules")
      .to_return(status: 200, body: JSON.generate("result" => { "id" => "rule-1" }))

    make.provision(address: ADDRESS, worker_name: WORKER)
    assert_requested(create_stub)
    WebMock.assert_not_requested(:post, %r{email/routing/dns})
  end

  def test_provision_catch_all
    stub = stub_request(:put, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/rules/catch_all")
      .with { |req|
        body = JSON.parse(req.body)
        assert_equal [{ "type" => "all" }], body["matchers"]
        assert_equal [{ "type" => "worker", "value" => [WORKER] }], body["actions"]
        true
      }
      .to_return(status: 200, body: JSON.generate("result" => { "id" => "catchall-1" }))

    make.provision_catch_all(zone_id: ZONE_ID, worker_name: WORKER)
    assert_requested(stub)
  end

  def test_provision_raises_if_no_zone_for_domain
    stub_request(:get, %r{zones\?name=})
      .to_return(status: 200, body: JSON.generate("result" => []))

    err = assert_raises(Cloudflare::Email::Error) do
      make.provision(address: "x@unknown.example", worker_name: WORKER)
    end
    assert_match(/No Cloudflare zone/, err.message)
  end

  def test_subdomain_requires_onboarding_before_rule_mutation
    stub_zones
    stub_subdomain_dns([])
    error = assert_raises(Cloudflare::Email::Error) { make.provision(address: ADDRESS, worker_name: WORKER) }
    assert_match(/Settings > Subdomains/, error.message)
    WebMock.assert_not_requested(:post, %r{email/routing})
  end

  def test_subdomain_rejects_conflicting_mx
    stub_zones
    stub_subdomain_dns(routing_dns + [{ "type" => "MX", "content" => "mail.other.example" }])
    assert_raises(Cloudflare::Email::Error) { make.provision(address: ADDRESS, worker_name: WORKER) }
    WebMock.assert_not_requested(:post, %r{email/routing})
  end

  def test_subdomain_dns_permission_failure_stops_rule_creation
    stub_zones
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/dns_records?name=#{DOMAIN}&per_page=50&page=1")
      .to_return(status: 403, body: JSON.generate("errors" => [{ "message" => "DNS Read permission required" }]))
    error = assert_raises(Cloudflare::Email::Error) { make.provision(address: ADDRESS, worker_name: WORKER) }
    assert_match(/DNS Read permission required/, error.message)
    WebMock.assert_not_requested(:post, %r{email/routing})
  end

  def test_subdomain_rejects_multiple_spf_policies
    stub_zones
    stub_subdomain_dns(routing_dns + [{ "type" => "TXT", "content" => "v=spf1 include:other.example ~all" }])
    assert_raises(Cloudflare::Email::Error) { make.provision(address: ADDRESS, worker_name: WORKER) }
    WebMock.assert_not_requested(:post, %r{email/routing})
  end

  def test_malformed_settings_do_not_trigger_enablement
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing")
      .to_return(status: 200, body: JSON.generate("result" => {}))
    error = assert_raises(Cloudflare::Email::Error) { make.enable_routing_if_needed(ZONE_ID) }
    assert_match(/enabled flag/, error.message)
    WebMock.assert_not_requested(:post, %r{email/routing})
  end

  def test_subdomain_catchall_cannot_change_parent_zone
    stub_zones
    error = assert_raises(Cloudflare::Email::Error) { make.provision_catch_all_for_domain(domain: DOMAIN, worker_name: WORKER) }
    assert_match(/zone-wide/, error.message)
    WebMock.assert_not_requested(:put, /catch_all/)
    WebMock.assert_not_requested(:post, %r{email/routing})
  end

  def test_rule_lookup_follows_pagination
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/rules?per_page=50&page=1")
      .to_return(status: 200, body: JSON.generate("result" => [{ "id" => "unrelated" }], "result_info" => { "total_pages" => 2 }))
    existing = { "id" => "later-page", "matchers" => [{ "field" => "to", "type" => "literal", "value" => ADDRESS }] }
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/rules?per_page=50&page=2")
      .to_return(status: 200, body: JSON.generate("result" => [existing], "result_info" => { "total_pages" => 2 }))
    update = stub_request(:put, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/rules/later-page")
      .to_return(status: 200, body: JSON.generate("result" => existing))
    make.upsert_route(zone_id: ZONE_ID, address: ADDRESS, worker_name: WORKER)
    assert_requested update
    WebMock.assert_not_requested(:post, %r{email/routing/rules})
  end

  def test_success_false_response_is_an_error
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing")
      .to_return(status: 200, body: JSON.generate("success" => false, "errors" => [{ "message" => "Denied" }]))
    error = assert_raises(Cloudflare::Email::Error) { make.enable_routing_if_needed(ZONE_ID) }
    assert_match(/Denied/, error.message)
    WebMock.assert_not_requested(:post, %r{email/routing})
  end

  def test_enable_failure_stops_provisioning
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones?name=example.com")
      .to_return(status: 200, body: JSON.generate("result" => [{ "id" => ZONE_ID }]))
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing")
      .to_return(status: 200, body: JSON.generate("result" => { "enabled" => false }))
    stub_request(:post, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/dns")
      .to_return(status: 403, body: JSON.generate("errors" => [{ "message" => "Insufficient permissions" }]))
    assert_raises(Cloudflare::Email::Error) { make.provision(address: "user@example.com", worker_name: WORKER) }
    WebMock.assert_not_requested(:post, %r{email/routing/rules})
  end

  private

  def stub_zones
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones?name=in.example.com")
      .to_return(status: 200, body: JSON.generate("result" => []))
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones?name=example.com")
      .to_return(status: 200, body: JSON.generate("result" => [{ "id" => ZONE_ID, "name" => PARENT }]))
  end

  def routing_dns
    (1..3).map { |n| { "type" => "MX", "content" => "route#{n}.mx.cloudflare.net" } } +
      [{ "type" => "TXT", "content" => "v=spf1 include:_spf.mx.cloudflare.net ~all" }]
  end

  def stub_subdomain_dns(records = routing_dns)
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/dns_records?name=#{DOMAIN}&per_page=50&page=1")
      .to_return(status: 200, body: JSON.generate("result" => records))
  end


  def assert_not_requested(method, url)
    refute WebMock::RequestRegistry.instance.times_executed(
      WebMock::RequestPattern.new(method, url).to_s,
    ).positive?
  rescue StandardError
    # Fallback: use WebMock's own assertion.
    WebMock.assert_not_requested(method, url)
  end
end
