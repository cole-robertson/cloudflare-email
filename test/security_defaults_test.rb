require "test_helper"
require "cloudflare/email/endpoint"
require "cloudflare/email/dev_ingress_guard"
require "cloudflare/email/dev_tunnel"

class SecurityDefaultsTest < Minitest::Test
  def test_endpoint_policy_preserves_https_and_loopback_only
    ["https://api.example.test/v4", "http://localhost:3000", "http://127.0.0.1:3000", "http://[::1]:3000"].each do |value|
      assert_equal value, Cloudflare::Email::Endpoint.parse(value).to_s
    end
    ["http://app.example.test", "https://user:password@app.example.test", "https://app.example.test/#section", "https://app.example.test/?option=1", "relative-path"].each do |value|
      assert_raises(Cloudflare::Email::ConfigurationError) { Cloudflare::Email::Endpoint.parse(value) }
    end
    assert_raises(Cloudflare::Email::ConfigurationError) { Cloudflare::Email::Endpoint.parse("http://localhost:3000", allow_loopback: false) }
  end

  def test_client_rejects_non_identifier_accounts_and_insecure_remote_endpoints_before_requests
    assert_raises(Cloudflare::Email::ConfigurationError) { make_client(account_id: "two accounts") }
    assert_raises(Cloudflare::Email::ConfigurationError) { make_client(base_url: "http://app.example.test") }
    assert_equal "https://api.example.test/v4", make_client(base_url: "https://api.example.test/v4/").base_url
    refute_includes make_client.inspect, API_TOKEN
  end

  def test_retry_logging_does_not_include_provider_message_text
    warnings = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |message| warnings << message }
    stub_request(:post, send_endpoint).to_return(status: 429,
      body: JSON.generate(success: false, errors: [{ message: "private email details" }]))
      .then.to_return(body: JSON.generate(cloudflare_success_body))
    make_client(retries: 1, logger: logger).send(from: "sender@example.com", to: "user@example.com", subject: "hello", text: "body")
    assert_equal 1, warnings.length
    refute_includes warnings.first, "private email details"
  end

  def test_explicit_success_flags_must_be_boolean_and_http_status_successful
    [nil, "true", "false", 1].each do |flag|
      refute Cloudflare::Email::Response.new({ "success" => flag }).success?
      stub_request(:post, send_endpoint).to_return(body: JSON.generate(success: flag, result: { message_id: "message" }))
      assert_raises(Cloudflare::Email::Error) { make_client.send(from: "a@example.com", to: "b@example.com", subject: "s", text: "t") }
    end
    refute Cloudflare::Email::Response.new({ "success" => true }, status: 500).success?
    [true, {}, 1, ""].each do |id|
      response = Cloudflare::Email::Response.new({ "success" => true, "result" => { "message_id" => id } })
      assert_nil response.message_id
      refute response.accepted?
    end
    refute Cloudflare::Email::Response.new({ "success" => true, "result" => { "queued" => "unexpected scalar" } }).accepted?
  end

  def test_tunnel_host_restricts_path_and_method_before_application
    calls = []
    guard = Cloudflare::Email::DevIngressGuard
    app = guard.new(->(env) { calls << env; [200, {}, ["application"]] })
    ["/", "/other"].each do |path|
      response = app.call("HTTP_HOST" => guard::HOST, "REQUEST_METHOD" => "GET", "PATH_INFO" => path)
      assert_equal 404, response.first
      assert_equal "1", response[1][guard::RESPONSE_HEADER]
    end
    assert_equal 404, app.call("HTTP_HOST" => guard::HOST, "REQUEST_METHOD" => "GET", "PATH_INFO" => guard::PATH).first
    assert_empty calls
    assert_equal 200, app.call("HTTP_HOST" => guard::HOST, "REQUEST_METHOD" => "POST", "PATH_INFO" => guard::PATH,
      "HTTP_X_FORWARDED_HOST" => "public.example.test", "HTTP_FORWARDED" => "host=public.example.test").first
    assert_equal "localhost", calls.last["HTTP_HOST"]
    refute calls.last.key?("HTTP_X_FORWARDED_HOST")
    refute calls.last.key?("HTTP_FORWARDED")
    assert_equal 200, app.call("HTTP_HOST" => "localhost", "REQUEST_METHOD" => "GET", "PATH_INFO" => "/").first
  end

  def test_tunnel_requires_running_guard_before_public_exposure
    tunnel = Cloudflare::Email::DevTunnel.new(port: 3456)
    stub_request(:get, "http://127.0.0.1:3456/").with(headers: { "Host" => Cloudflare::Email::DevIngressGuard::HOST })
      .to_return(status: 404)
    assert_raises(RuntimeError) { tunnel.send(:verify_ingress_guard!) }
    stub_request(:get, "http://127.0.0.1:3456/").with(headers: { "Host" => Cloudflare::Email::DevIngressGuard::HOST })
      .to_return(status: 404, headers: { Cloudflare::Email::DevIngressGuard::RESPONSE_HEADER => "1" })
    tunnel.send(:verify_ingress_guard!)
  end
end
