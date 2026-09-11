require "test_helper"
require "cloudflare/email/routing_diagnostics"
require "cloudflare/email/check_route_task"

class RoutingDiagnosticsTest < Minitest::Test
  BASE = "https://api.cloudflare.com/client/v4".freeze
  ADDRESS = "bot@in.example.com".freeze
  WORKER = "ingress".freeze

  def setup
    super
    list("/zones?name=in.example.com", [])
    list("/zones?name=example.com", [{ id: "zone", name: "example.com", account: { id: "account" } }])
    response("/zones/zone/email/routing", { enabled: true })
    list("/zones/zone/dns_records?name=in.example.com", dns_records)
    list("/zones/zone/email/routing/rules", [])
    response("/zones/zone/email/routing/rules/catch_all", catch_all)
  end

  def response(path, result, **extra)
    stub_request(:get, "#{BASE}#{path}").with(headers: { "Authorization" => "Bearer secret" })
      .to_return(status: 200, body: JSON.generate({ result: result, success: true }.merge(extra)))
  end

  def list(path, result, page: 1, **extra)
    response("#{path}#{path.include?('?') ? '&' : '?'}per_page=50&page=#{page}", result, **extra)
  end

  def dns_records
    (1..3).map { |n| { name: "in.example.com", type: "MX", content: "route#{n}.mx.cloudflare.net" } } +
      [{ name: "in.example.com", type: "TXT", content: "v=spf1 include:_spf.mx.cloudflare.net ~all" }]
  end

  def catch_all
    { enabled: true, matchers: [{ type: "all" }], actions: [{ type: "worker", value: [WORKER] }] }
  end

  def literal(address: ADDRESS, worker: WORKER, enabled: true)
    { enabled: enabled, priority: 0, matchers: [{ field: "to", type: "literal", value: address }],
      actions: [{ type: "worker", value: [worker] }] }
  end

  def check(account_id: "account")
    Cloudflare::Email::RoutingDiagnostics.new(api_token: "secret").check(address: ADDRESS, worker_name: WORKER, account_id: account_id)
  end

  def status_for(name)
    check[:checks].find { |item| item[:name] == name }[:status]
  end

  def test_read_only_configuration_snapshot_passes_with_catchall
    report = check
    assert_equal "pass", report[:status]
    assert_includes report[:limitations], "does not prove"
    [:post, :put, :delete, :patch].each { |method| assert_not_requested method, /api.cloudflare.com/ }
  end

  def test_parent_google_mx_does_not_conflict_with_receiving_subdomain
    list("/zones/zone/dns_records?name=in.example.com", dns_records + [{ name: "example.com", type: "MX", content: "aspmx.l.google.com" }])
    assert_equal "pass", status_for("dns")
  end

  def test_parent_records_cannot_satisfy_subdomain_dns
    list("/zones/zone/dns_records?name=in.example.com", dns_records.map { |r| r.merge(name: "example.com") })
    assert_equal "fail", status_for("dns")
  end

  def test_conflicting_mx_or_multiple_spf_fails
    list("/zones/zone/dns_records?name=in.example.com", dns_records + [{ name: "in.example.com", type: "MX", content: "aspmx.l.google.com" }])
    assert_equal "fail", status_for("dns")
    list("/zones/zone/dns_records?name=in.example.com", dns_records + [{ name: "in.example.com", type: "TXT", content: "v=spf1 -all" }])
    assert_equal "fail", status_for("dns")
  end

  def test_spf_include_after_all_does_not_pass
    records = dns_records
    records.last[:content] = "v=spf1 -all include:_spf.mx.cloudflare.net"
    list("/zones/zone/dns_records?name=in.example.com", records)
    assert_equal "fail", status_for("dns")
  end

  def test_wrong_account_fails_and_missing_account_is_unknown
    assert_equal "fail", check(account_id: "other")[:status]
    list("/zones?name=example.com", [{ id: "zone", name: "example.com" }])
    assert_equal "unknown", status_for("account")
    assert_equal "pass", check(account_id: nil)[:status]
  end

  def test_disabled_routing_fails
    response("/zones/zone/email/routing", { enabled: false })
    assert_equal "fail", status_for("routing")
  end

  def test_missing_enabled_flag_is_not_success
    response("/zones/zone/email/routing", {})
    assert_equal "unknown", status_for("routing")
  end

  def test_explicit_wrong_worker_shadows_good_catchall
    list("/zones/zone/email/routing/rules", [literal(worker: "different")])
    assert_equal "fail", status_for("route")
    assert_not_requested :get, "#{BASE}/zones/zone/email/routing/rules/catch_all"
  end

  def test_explicit_drop_shadows_good_catchall
    list("/zones/zone/email/routing/rules", [literal.merge(actions: [{ type: "drop" }])])
    assert_equal "fail", status_for("route")
  end

  def test_explicit_good_worker_wins_without_reading_disabled_catchall
    list("/zones/zone/email/routing/rules", [literal])
    response("/zones/zone/email/routing/rules/catch_all", catch_all.merge(enabled: false))
    assert_equal "pass", status_for("route")
    assert_not_requested :get, "#{BASE}/zones/zone/email/routing/rules/catch_all"
  end

  def test_disabled_literal_does_not_shadow_catchall
    list("/zones/zone/email/routing/rules", [literal(worker: "old", enabled: false)])
    assert_equal "pass", status_for("route")
  end

  def test_disabled_catchall_without_explicit_rule_fails
    response("/zones/zone/email/routing/rules/catch_all", catch_all.merge(enabled: false))
    assert_equal "fail", status_for("route")
  end

  def test_multiple_matching_rules_have_unverified_ordering_even_with_priority
    list("/zones/zone/email/routing/rules", [literal, literal(worker: "other")])
    assert_equal "unknown", status_for("route")
    list("/zones/zone/email/routing/rules", [literal, literal(worker: "other").merge(priority: 5)])
    assert_equal "unknown", status_for("route")
  end

  def test_unknown_matcher_cannot_be_ignored
    list("/zones/zone/email/routing/rules", [literal.merge(matchers: [{ field: "to", type: "regex", value: ".*" }])])
    assert_equal "unknown", status_for("route")
  end

  def test_explicit_route_on_later_page_shadows_catchall
    list("/zones/zone/email/routing/rules", [literal(address: "someone@in.example.com")], result_info: { total_pages: 2 })
    list("/zones/zone/email/routing/rules", [literal(worker: "other")], page: 2, result_info: { total_pages: 2 })
    assert_equal "fail", status_for("route")
  end

  def test_dns_pagination_collects_all_records
    list("/zones/zone/dns_records?name=in.example.com", dns_records.take(2), result_info: { total_pages: 2 })
    list("/zones/zone/dns_records?name=in.example.com", dns_records.drop(2), page: 2, result_info: { total_pages: 2 })
    assert_equal "pass", status_for("dns")
  end

  def test_pagination_limit_never_passes_partial_list
    1.upto(Cloudflare::Email::RoutingDiagnostics::MAX_PAGES) do |page|
      list("/zones/zone/email/routing/rules", [literal(address: "other@in.example.com")], page: page, result_info: { total_pages: 100 })
    end
    assert_equal "unknown", status_for("route")
    assert_not_requested :get, "#{BASE}/zones/zone/email/routing/rules?per_page=50&page=51"
  end

  def test_missing_zone_prevents_green_report
    list("/zones?name=example.com", [])
    assert_equal "fail", check[:status]
  end

  def test_duplicate_zones_are_unknown
    zone = { id: "zone", name: "example.com" }
    list("/zones?name=example.com", [zone, zone])
    assert_equal "unknown", check[:status]
  end

  def test_provider_errors_are_sanitized_and_do_not_stop_other_checks
    stub_request(:get, "#{BASE}/zones/zone/email/routing").to_return(status: 403, body: "secret token and upstream details")
    report = check
    assert_equal "unknown", report[:status]
    refute_includes JSON.generate(report), "secret"
    assert_equal "pass", report[:checks].find { |c| c[:name] == "route" }[:status]
  end

  def test_invalid_json_and_oversized_response_are_unknown
    stub_request(:get, "#{BASE}/zones/zone/email/routing").to_return(status: 200, body: "secret invalid json")
    assert_equal "unknown", status_for("routing")
    stub_request(:get, "#{BASE}/zones/zone/email/routing").to_return(status: 200, body: "x" * (Cloudflare::Email::RoutingDiagnostics::MAX_BYTES + 1))
    assert_equal "unknown", status_for("routing")
  end

  def test_timeout_is_unknown_and_does_not_stop_other_checks
    stub_request(:get, "#{BASE}/zones/zone/email/routing").to_timeout
    assert_equal "unknown", status_for("routing")
    assert_equal "pass", status_for("route")
  end

  def test_malformed_nested_provider_data_is_unknown
    list("/zones?name=example.com", [{ id: "zone", name: "example.com", account: "invalid" }])
    assert_equal "unknown", status_for("account")
    list("/zones/zone/email/routing/rules", [], result_info: "invalid")
    assert_equal "unknown", status_for("route")
  end

  def test_invalid_success_flag_is_not_accepted
    response("/zones/zone/email/routing", { enabled: true }, success: "yes")
    assert_equal "unknown", status_for("routing")
  end

  def test_unknown_matching_rule_enabled_state_does_not_fall_back
    list("/zones/zone/email/routing/rules", [literal.merge(enabled: nil)])
    assert_equal "unknown", status_for("route")
  end

  def test_task_returns_nonzero_for_unknown_and_does_not_echo_exceptions
    io = StringIO.new
    Cloudflare::Email::Credentials.stub(:management_token, "secret") do
      Cloudflare::Email::Credentials.stub(:account_id, "account") do
        assert_equal 0, Cloudflare::Email::CheckRouteTask.call(address: ADDRESS, worker_name: WORKER, io: io)
        response("/zones/zone/email/routing", {})
        assert_equal 1, Cloudflare::Email::CheckRouteTask.call(address: ADDRESS, worker_name: WORKER, io: io)
        assert_equal 1, Cloudflare::Email::CheckRouteTask.call(address: "secret-invalid-input", worker_name: WORKER, io: io)
      end
    end
    refute_includes io.string, "secret"
  end
end
