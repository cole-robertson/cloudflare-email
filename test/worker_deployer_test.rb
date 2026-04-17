require "test_helper"
require "cloudflare/email/worker_deployer"
require "tempfile"

class WorkerDeployerTest < Minitest::Test
  ACCOUNT = "acct-test".freeze
  TOKEN   = "cf-token".freeze
  SCRIPT  = "cloudflare-email-ingress-test".freeze  # matches what Rails.env returns in tests

  def make_deployer(**overrides)
    Cloudflare::Email::WorkerDeployer.new(
      account_id: ACCOUNT, api_token: TOKEN,
      script_name: overrides.delete(:script_name) || SCRIPT,
      **overrides,
    )
  end

  def test_default_script_name_uses_rails_env
    assert_equal "cloudflare-email-ingress-production",
                 Cloudflare::Email::WorkerDeployer.default_script_name_with_env("production")
  end

  def script_url
    "https://api.cloudflare.com/client/v4/accounts/#{ACCOUNT}/workers/scripts/#{SCRIPT}"
  end

  def secrets_url
    "#{script_url}/secrets"
  end

  def test_requires_account_id
    assert_raises(ArgumentError) do
      Cloudflare::Email::WorkerDeployer.new(account_id: "", api_token: TOKEN)
    end
  end

  def test_requires_api_token
    assert_raises(ArgumentError) do
      Cloudflare::Email::WorkerDeployer.new(account_id: ACCOUNT, api_token: nil)
    end
  end

  def test_deploy_uploads_script_as_multipart
    stub = stub_request(:put, script_url)
      .with { |req|
        assert_equal "Bearer #{TOKEN}", req.headers["Authorization"]
        assert_match %r{\Amultipart/form-data; boundary=----cf-email-}, req.headers["Content-Type"]
        body = req.body
        assert_match(/name="metadata"/, body)
        assert_match(/"main_module":"index.js"/, body)
        assert_match(/name="index.js"; filename="index.js"/, body)
        assert_match(/Content-Type: application\/javascript\+module/, body)
        assert_match(/export default \{/, body)
        true
      }
      .to_return(status: 200, body: JSON.generate("success" => true, "result" => { "id" => "abc" }))

    make_deployer.deploy(source: "export default { async email(message, env) {} };")

    assert_requested(stub)
  end

  def test_deploy_from_script_path
    source = "export default { hello: true };"
    tmp = Tempfile.new(%w[worker .js])
    tmp.write(source); tmp.close

    stub_request(:put, script_url)
      .with { |req| req.body.include?(source) }
      .to_return(status: 200, body: JSON.generate("success" => true, "result" => {}))

    make_deployer.deploy(script_path: tmp.path)
  ensure
    tmp&.unlink
  end

  def test_deploy_raises_on_failure
    stub_request(:put, script_url).to_return(
      status: 403,
      body: JSON.generate("errors" => [{ "message" => "Authentication error" }]),
    )

    err = assert_raises(Cloudflare::Email::Error) do
      make_deployer.deploy(source: "x")
    end
    assert_equal 403, err.status
    assert_match(/Authentication error/, err.message)
  end

  def test_put_secret_posts_json
    stub = stub_request(:put, secrets_url)
      .with(
        headers: {
          "Authorization" => "Bearer #{TOKEN}",
          "Content-Type"  => "application/json",
        }
      ) { |req|
        body = JSON.parse(req.body)
        assert_equal "INGRESS_SECRET", body["name"]
        assert_equal "hunter2",        body["text"]
        assert_equal "secret_text",    body["type"]
        true
      }
      .to_return(status: 200, body: JSON.generate("success" => true))

    make_deployer.put_secret("INGRESS_SECRET", "hunter2")
    assert_requested(stub)
  end

  def test_delete_secret
    stub = stub_request(:delete, "#{secrets_url}/INGRESS_SECRET")
      .to_return(status: 200, body: JSON.generate("success" => true))

    make_deployer.delete_secret("INGRESS_SECRET")
    assert_requested(stub)
  end

  def test_exists_true_on_200
    stub_request(:get, script_url).to_return(status: 200, body: JSON.generate("result" => {}))
    assert make_deployer.exists?
  end

  def test_exists_false_on_404
    stub_request(:get, script_url).to_return(status: 404, body: JSON.generate("errors" => []))
    refute make_deployer.exists?
  end

  def test_delete_script
    stub = stub_request(:delete, script_url).to_return(status: 200, body: JSON.generate("success" => true))
    make_deployer.delete_script
    assert_requested(stub)
  end
end
