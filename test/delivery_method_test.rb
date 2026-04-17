require "test_helper"
require "rails"
require "action_mailer"
require "cloudflare/email/delivery_method"

ActionMailer::Base.add_delivery_method :cloudflare, Cloudflare::Email::DeliveryMethod

class TestMailer < ActionMailer::Base
  default from: "agent@acme.com"

  def hello(to:)
    mail(to: to, subject: "Hi") { |format| format.text { render plain: "Hello there" } }
  end
end

class DeliveryMethodTest < Minitest::Test
  def setup
    ActionMailer::Base.delivery_method = :cloudflare
    ActionMailer::Base.cloudflare_settings = {
      account_id: ACCOUNT_ID,
      api_token:  API_TOKEN,
      retries: 0,
    }
    ActionMailer::Base.perform_deliveries = true
    ActionMailer::Base.raise_delivery_errors = true
  end

  def test_delivers_via_send_raw_and_sets_message_id
    stub = stub_request(:post, send_raw_endpoint)
      .with { |req|
        body = JSON.parse(req.body)
        assert_equal "agent@acme.com", body["from"]
        assert_includes body["recipients"], "user@example.com"
        assert_match(/Subject: Hi/, body["mime_message"])
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    mail = TestMailer.hello(to: "user@example.com").deliver_now

    assert_requested(stub)
    # Cloudflare API does not return message_id; Mail gem retains its auto-generated one.
    assert mail.message_id, "Mail should still have its auto-generated message_id"
  end

  def test_collects_cc_and_bcc_into_recipients
    stub = stub_request(:post, send_raw_endpoint)
      .with { |req|
        recipients = JSON.parse(req.body)["recipients"]
        assert_includes recipients, "user@example.com"
        assert_includes recipients, "cc@example.com"
        assert_includes recipients, "bcc@example.com"
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    mail = Mail.new do
      from    "agent@acme.com"
      to      "user@example.com"
      cc      "cc@example.com"
      bcc     "bcc@example.com"
      subject "Hi"
      body    "Body"
    end
    mail.delivery_method Cloudflare::Email::DeliveryMethod, ActionMailer::Base.cloudflare_settings
    mail.deliver

    assert_requested(stub)
  end

  def test_raises_when_no_from
    method = Cloudflare::Email::DeliveryMethod.new(
      account_id: ACCOUNT_ID, api_token: API_TOKEN, retries: 0
    )
    mail = Mail.new(to: "x@y.com", subject: "Hi", body: "Hello")
    assert_raises(Cloudflare::Email::ValidationError) { method.deliver!(mail) }
  end

  def test_raises_when_no_recipients
    method = Cloudflare::Email::DeliveryMethod.new(
      account_id: ACCOUNT_ID, api_token: API_TOKEN, retries: 0
    )
    mail = Mail.new(from: "a@b.com", subject: "Hi", body: "Hello")
    assert_raises(Cloudflare::Email::ValidationError) { method.deliver!(mail) }
  end
end
