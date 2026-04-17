require "test_helper"
require "rails"
require "action_mailer"
require "cloudflare/email/delivery_method"

ActionMailer::Base.add_delivery_method :cloudflare, Cloudflare::Email::DeliveryMethod unless
  ActionMailer::Base.delivery_methods.key?(:cloudflare)

class MultipartMailer < ActionMailer::Base
  default from: "agent@acme.com"

  def with_html_and_text(to:)
    mail(to: to, subject: "Multi") do |format|
      format.text { render plain: "Plain body" }
      format.html { render html: "<b>HTML body</b>".html_safe }
    end
  end

  def with_attachment(to:)
    attachments["report.txt"] = "file contents"
    mail(to: to, subject: "With attachment") do |format|
      format.text { render plain: "See attachment" }
    end
  end

  def with_threading(to:, in_reply_to:)
    headers["In-Reply-To"] = in_reply_to
    headers["References"]  = in_reply_to
    mail(to: to, subject: "Re: thread") do |format|
      format.text { render plain: "reply" }
    end
  end
end

class DeliveryMethodAdvancedTest < Minitest::Test
  def setup
    ActionMailer::Base.delivery_method = :cloudflare
    ActionMailer::Base.cloudflare_settings = {
      account_id: ACCOUNT_ID, api_token: API_TOKEN, retries: 0,
    }
    ActionMailer::Base.raise_delivery_errors = true
    ActionMailer::Base.perform_deliveries = true
  end

  def test_multipart_mail_forwards_full_mime
    stub_request(:post, send_raw_endpoint)
      .with { |req|
        mime = JSON.parse(req.body)["mime_message"]
        assert_match(/multipart\/alternative/i, mime)
        assert_match(/Plain body/,  mime)
        assert_match(/HTML body/,   mime)
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    MultipartMailer.with_html_and_text(to: "user@example.com").deliver_now
  end

  def test_attachment_round_trips_as_mime
    stub_request(:post, send_raw_endpoint)
      .with { |req|
        mime = JSON.parse(req.body)["mime_message"]
        assert_match(/Content-Disposition:.*?attachment.*?filename=["]?report\.txt/m, mime)
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    MultipartMailer.with_attachment(to: "user@example.com").deliver_now
  end

  def test_threading_headers_round_trip
    stub_request(:post, send_raw_endpoint)
      .with { |req|
        mime = JSON.parse(req.body)["mime_message"]
        assert_match(/In-Reply-To: <msg-1@acme\.com>/, mime)
        assert_match(/References: <msg-1@acme\.com>/,  mime)
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    MultipartMailer.with_threading(
      to: "user@example.com",
      in_reply_to: "<msg-1@acme.com>",
    ).deliver_now
  end

  def test_auth_error_propagates_to_caller
    stub_request(:post, send_raw_endpoint)
      .to_return(status: 401, body: JSON.generate(cloudflare_error_body("bad token")))

    assert_raises(Cloudflare::Email::AuthenticationError) do
      MultipartMailer.with_html_and_text(to: "user@example.com").deliver_now
    end
  end

  def test_settings_without_account_id_raises_clear_error
    ActionMailer::Base.cloudflare_settings = { api_token: API_TOKEN, retries: 0 }

    assert_raises(KeyError, ArgumentError) do
      MultipartMailer.with_html_and_text(to: "user@example.com").deliver_now
    end
  end

  def test_recipients_deduplicated
    # If same address is in both to and cc, Cloudflare shouldn't get it twice.
    mail = Mail.new do
      from    "agent@acme.com"
      to      "user@example.com"
      cc      "user@example.com"
      subject "Hi"
      body    "Body"
    end

    stub_request(:post, send_raw_endpoint)
      .with { |req|
        rcpts = JSON.parse(req.body)["recipients"]
        assert_equal 1, rcpts.count { |r| r == "user@example.com" }
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    mail.delivery_method Cloudflare::Email::DeliveryMethod, ActionMailer::Base.cloudflare_settings
    mail.deliver
  end
end
