require "test_helper"

# Deeper Client coverage: attachments, cc/bcc/reply_to, threading headers,
# custom base_url, logger, send_raw address shapes, concurrent access.
class ClientAdvancedTest < Minitest::Test
  def test_send_forwards_cc_bcc_and_reply_to
    stub_request(:post, send_endpoint)
      .with { |req|
        body = JSON.parse(req.body)
        assert_equal ["cc1@example.com", "cc2@example.com"], body["cc"]
        assert_equal ["bcc@example.com"], body["bcc"]
        assert_equal "replies@acme.com", body["reply_to"]
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    make_client.send(
      from: "a@b.com", to: "c@d.com", subject: "x", text: "y",
      cc:  ["cc1@example.com", "cc2@example.com"],
      bcc: "bcc@example.com",
      reply_to: "replies@acme.com",
    )
  end

  def test_send_forwards_threading_headers
    stub_request(:post, send_endpoint)
      .with { |req|
        headers = JSON.parse(req.body)["headers"]
        assert_equal "<prev-msg@acme.com>", headers["In-Reply-To"]
        assert_equal "<prev-msg@acme.com> <earlier@acme.com>", headers["References"]
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    make_client.send(
      from: "a@b.com", to: "c@d.com", subject: "x", text: "y",
      headers: {
        "In-Reply-To" => "<prev-msg@acme.com>",
        "References"  => "<prev-msg@acme.com> <earlier@acme.com>",
      },
    )
  end

  def test_send_forwards_attachments
    attachment = {
      content:  "aGVsbG8=",
      filename: "hi.txt",
      type:     "text/plain",
      disposition: "attachment",
    }

    stub_request(:post, send_endpoint)
      .with { |req|
        att = JSON.parse(req.body)["attachments"]
        assert_equal 1, att.size
        assert_equal "hi.txt", att.first["filename"]
        assert_equal "aGVsbG8=", att.first["content"]
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    make_client.send(
      from: "a@b.com", to: "c@d.com", subject: "x", text: "y",
      attachments: [attachment],
    )
  end

  def test_send_accepts_both_text_and_html
    stub_request(:post, send_endpoint)
      .with { |req|
        body = JSON.parse(req.body)
        assert_equal "text body", body["text"]
        assert_equal "<p>html body</p>", body["html"]
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    make_client.send(
      from: "a@b.com", to: "c@d.com", subject: "x",
      text: "text body", html: "<p>html body</p>",
    )
  end

  def test_send_accepts_array_of_recipients
    stub_request(:post, send_endpoint)
      .with { |req|
        assert_equal ["a@a.com", "b@b.com"], JSON.parse(req.body)["to"]
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    make_client.send(
      from: "x@y.com", to: ["a@a.com", "b@b.com"],
      subject: "x", text: "y",
    )
  end

  def test_send_normalizes_string_keys_in_address_hash
    stub_request(:post, send_endpoint)
      .with { |req|
        body = JSON.parse(req.body)
        assert_equal({ "address" => "agent@acme.com", "name" => "Acme" }, body["from"])
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    make_client.send(
      from: { "address" => "agent@acme.com", "name" => "Acme" },
      to:   "c@d.com", subject: "x", text: "y",
    )
  end

  def test_send_rejects_bad_address_shape
    assert_raises(Cloudflare::Email::ValidationError) do
      make_client.send(from: 123, to: "c@d.com", subject: "x", text: "y")
    end
  end

  def test_send_rejects_address_hash_without_address_key
    assert_raises(Cloudflare::Email::ValidationError) do
      make_client.send(
        from: { name: "No Address" },
        to: "c@d.com", subject: "x", text: "y",
      )
    end
  end

  def test_custom_base_url
    stub_request(:post, "https://api.example.test/v1/accounts/#{ACCOUNT_ID}/email/sending/send")
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    client = Cloudflare::Email::Client.new(
      account_id: ACCOUNT_ID, api_token: API_TOKEN,
      base_url: "https://api.example.test/v1", retries: 0,
    )
    assert client.send(from: "a@b.com", to: "c@d.com", subject: "x", text: "y").success?
  end

  def test_sends_user_agent_header
    stub_request(:post, send_endpoint)
      .with(headers: { "User-Agent" => /cloudflare-email-ruby\/\d+\.\d+\.\d+/ })
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    make_client.send(from: "a@b.com", to: "c@d.com", subject: "x", text: "y")
  end

  def test_logger_receives_retry_warnings
    logger = Minitest::Mock.new
    logger.expect(:warn, nil) { |msg| msg.include?("retry") }

    stub_request(:post, send_endpoint)
      .to_return(status: 503, body: JSON.generate(cloudflare_error_body("down")))
      .then.to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    client = Cloudflare::Email::Client.new(
      account_id: ACCOUNT_ID, api_token: API_TOKEN,
      retries: 1, initial_backoff: 0.0, logger: logger,
    )
    client.send(from: "a@b.com", to: "c@d.com", subject: "x", text: "y")
    logger.verify
  end

  def test_send_raw_with_hash_address_extracts_address
    stub_request(:post, send_raw_endpoint)
      .with { |req|
        body = JSON.parse(req.body)
        assert_equal "agent@acme.com", body["from"]
        assert_equal ["user@example.com"], body["recipients"]
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    make_client.send_raw(
      from: { address: "agent@acme.com", name: "Acme" },
      recipients: { address: "user@example.com" },
      mime_message: "From: x\r\nSubject: y\r\n\r\nbody",
    )
  end

  def test_send_raw_preserves_crlf_and_unicode
    mime = "From: a@b.com\r\nTo: c@d.com\r\nSubject: =?UTF-8?B?4pyTIGFjY2VwdGVk?=\r\n" \
           "Content-Type: text/plain; charset=UTF-8\r\n\r\nCafé ☕\r\n"

    stub_request(:post, send_raw_endpoint)
      .with { |req|
        body = JSON.parse(req.body)
        assert_equal mime, body["mime_message"]
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    make_client.send_raw(
      from: "a@b.com", recipients: "c@d.com", mime_message: mime,
    )
  end

  def test_rate_limit_error_exhausted_raises_rate_limit_error
    stub_request(:post, send_endpoint)
      .to_return(status: 429, body: JSON.generate(cloudflare_error_body("slow down")))

    err = assert_raises(Cloudflare::Email::RateLimitError) do
      make_client(retries: 0).send(from: "a@b.com", to: "c@d.com", subject: "x", text: "y")
    end
    assert_equal 429, err.status
  end

  def test_network_error_exhausted_raises_network_error
    stub_request(:post, send_endpoint).to_raise(Errno::ECONNRESET)

    err = assert_raises(Cloudflare::Email::NetworkError) do
      make_client(retries: 0).send(from: "a@b.com", to: "c@d.com", subject: "x", text: "y")
    end
    assert_match(/ECONNRESET|Connection reset/i, err.message)
  end

  def test_unexpected_status_raises_base_error
    stub_request(:post, send_endpoint)
      .to_return(status: 418, body: JSON.generate(cloudflare_error_body("teapot")))

    err = assert_raises(Cloudflare::Email::Error) do
      make_client.send(from: "a@b.com", to: "c@d.com", subject: "x", text: "y")
    end
    assert_equal 418, err.status
  end
end
