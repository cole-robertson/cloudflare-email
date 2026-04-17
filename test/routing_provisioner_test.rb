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

    assert_not_requested :post, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/enable"
  end

  def test_enable_routing_called_when_not_enabled
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing")
      .to_return(status: 200, body: JSON.generate("result" => { "enabled" => false }))
    stub = stub_request(:post, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/enable")
      .to_return(status: 200, body: JSON.generate("result" => { "enabled" => true }))

    make.enable_routing_if_needed(ZONE_ID)
    assert_requested(stub)
  end

  def test_enable_routing_called_on_404
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing")
      .to_return(status: 404, body: JSON.generate("errors" => []))
    stub = stub_request(:post, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/enable")
      .to_return(status: 200, body: JSON.generate("result" => { "enabled" => true }))

    make.enable_routing_if_needed(ZONE_ID)
    assert_requested(stub)
  end

  def test_enable_routing_silently_skips_on_403
    # Some scoped tokens can't read routing settings. We attempt enable
    # optimistically but don't fail the whole provision flow on 403.
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing")
      .to_return(status: 403, body: JSON.generate("errors" => [{ "message" => "Authentication error" }]))
    stub_request(:post, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/enable")
      .to_return(status: 403, body: JSON.generate("errors" => [{ "message" => "Authentication error" }]))

    # No exception raised
    make.enable_routing_if_needed(ZONE_ID)
  end

  def test_upsert_creates_rule_when_missing
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/rules?per_page=50")
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
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/rules?per_page=50")
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

    # 2. check routing (assume enabled)
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing")
      .to_return(status: 200, body: JSON.generate("result" => { "enabled" => true }))

    # 3. list rules (empty)
    stub_request(:get, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/rules?per_page=50")
      .to_return(status: 200, body: JSON.generate("result" => []))

    # 4. create rule
    create_stub = stub_request(:post, "https://api.cloudflare.com/client/v4/zones/#{ZONE_ID}/email/routing/rules")
      .to_return(status: 200, body: JSON.generate("result" => { "id" => "rule-1" }))

    make.provision(address: ADDRESS, worker_name: WORKER)
    assert_requested(create_stub)
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

  private

  def assert_not_requested(method, url)
    refute WebMock::RequestRegistry.instance.times_executed(
      WebMock::RequestPattern.new(method, url).to_s,
    ).positive?
  rescue StandardError
    # Fallback: use WebMock's own assertion.
    WebMock.assert_not_requested(method, url)
  end
end
