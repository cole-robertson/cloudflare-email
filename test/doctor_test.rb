require "test_helper"
require "stringio"
require "cloudflare/email/doctor"
require "cloudflare/email/send_test"

class DoctorTest < Minitest::Test
  def setup
    @io = StringIO.new
    @doctor = Cloudflare::Email::Doctor.new(io: @io)
  end

  def results
    @doctor.instance_variable_get(:@results)
  end

  def test_credentials_do_not_print_token_prefix
    @doctor.stub(:credential, ->(key) { key == :api_token ? "sensitive-token-value" : ACCOUNT_ID }) do
      @doctor.send(:check_credentials)
      @doctor.send(:summary)
    end
    refute_includes @io.string, "sensitiv"
    assert_includes @io.string, "redacted"
  end

  def test_forbidden_account_is_unverified_not_successful
    stub_request(:get, "https://api.cloudflare.com/client/v4/accounts/#{ACCOUNT_ID}")
      .to_return(status: 403, body: JSON.generate(cloudflare_error_body("Forbidden")))
    @doctor.stub(:credential, ->(key) { key == :api_token ? API_TOKEN : ACCOUNT_ID }) do
      @doctor.send(:check_account_access)
    end
    assert_equal :skip, results.last[:status]
    assert_match(/unverified/, results.last[:detail])
  end

  def test_sending_domains_directs_to_dashboard_without_unsupported_api_call
    @doctor.send(:check_sending_domains)
    assert_equal :skip, results.last[:status]
    assert_match(/dashboard/, results.last[:detail])
    WebMock.assert_not_requested(:get, %r{email/sending/domains})
  end

  def test_send_only_configuration_skips_inbound_requirements
    @doctor.stub(:inbound_enabled?, false) do
      @doctor.send(:check_ingress_secret)
      @doctor.send(:check_token_split)
    end
    assert results.all? { |result| result[:status] == :skip }
  end

  def test_explicit_inbound_configuration_warns_on_missing_secret
    @doctor.stub(:inbound_enabled?, true) do
      Cloudflare::Email::Credentials.stub(:ingress_secret, "") { @doctor.send(:check_ingress_secret) }
    end
    assert_equal :warn, results.last[:status]
  end

  def test_test_send_requires_explicit_sender_without_domain_lookup
    task = Cloudflare::Email::SendTest.new(io: @io, to: "to@example.net")
    task.stub(:account_id, ACCOUNT_ID) do
      task.stub(:api_token, API_TOKEN) { assert_equal 1, task.call }
    end
    assert_includes @io.string, "Missing FROM="
    WebMock.assert_not_requested(:get, %r{email/sending/domains})
    WebMock.assert_not_requested(:post, send_endpoint)
  end

  def test_test_send_reports_suppression_and_message_id
    payload = cloudflare_success_body(delivered: [])
    payload["result"].merge!("message_id" => "platform-id", "suppressed_recipients" => ["to@example.net"])
    stub_request(:post, send_endpoint).to_return(status: 200, body: JSON.generate(payload))
    task = Cloudflare::Email::SendTest.new(io: @io, to: "to@example.net", from: "sender@example.com")
    task.stub(:account_id, ACCOUNT_ID) do
      task.stub(:api_token, API_TOKEN) { assert_equal 0, task.call }
    end
    assert_includes @io.string, "platform-id"
    assert_includes @io.string, "suppressed:"
  end
end
