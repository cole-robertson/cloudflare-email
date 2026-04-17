require "test_helper"

class ClientTest < Minitest::Test
  def test_requires_account_id
    err = assert_raises(Cloudflare::Email::ConfigurationError) do
      Cloudflare::Email::Client.new(account_id: nil, api_token: "x")
    end
    assert_match(/account_id/, err.message)
  end

  def test_requires_api_token
    err = assert_raises(Cloudflare::Email::ConfigurationError) do
      Cloudflare::Email::Client.new(account_id: "a", api_token: "")
    end
    assert_match(/api_token/, err.message)
  end

  def test_send_posts_structured_body_and_returns_response
    stub = stub_request(:post, send_endpoint)
      .with(
        headers: {
          "Authorization" => "Bearer #{API_TOKEN}",
          "Content-Type"  => "application/json",
        }
      ) { |req|
        body = JSON.parse(req.body)
        assert_equal "agent@acme.com", body["from"]
        assert_equal ["user@example.com"], body["to"]
        assert_equal "Hi", body["subject"]
        assert_equal "Hello", body["text"]
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    response = make_client.send(
      from: "agent@acme.com",
      to:   "user@example.com",
      subject: "Hi",
      text: "Hello",
    )

    assert_kind_of Cloudflare::Email::Response, response
    assert response.success?
    assert_nil response.message_id  # Cloudflare API does not return message_id
    assert_equal ["user@example.com"], response.delivered
    assert_requested(stub)
  end

  def test_send_normalizes_hash_addresses
    stub_request(:post, send_endpoint)
      .with { |req|
        body = JSON.parse(req.body)
        assert_equal({ "address" => "agent@acme.com", "name" => "Acme" }, body["from"])
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    make_client.send(
      from: { address: "agent@acme.com", name: "Acme" },
      to:   "user@example.com",
      subject: "Hi",
      text: "Hello",
    )
  end

  def test_send_requires_text_or_html
    err = assert_raises(Cloudflare::Email::ValidationError) do
      make_client.send(from: "a@b.com", to: "c@d.com", subject: "x")
    end
    assert_match(/text.*html/, err.message)
  end

  def test_send_raw_posts_mime
    stub_request(:post, send_raw_endpoint)
      .with { |req|
        body = JSON.parse(req.body)
        assert_equal "agent@acme.com", body["from"]
        assert_equal ["user@example.com"], body["recipients"]
        assert_match(/Subject: Hi/, body["mime_message"])
        true
      }
      .to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    response = make_client.send_raw(
      from: "agent@acme.com",
      recipients: "user@example.com",
      mime_message: "From: agent@acme.com\r\nTo: user@example.com\r\nSubject: Hi\r\n\r\nbody",
    )

    assert response.success?
  end

  def test_401_raises_authentication_error
    stub_request(:post, send_endpoint)
      .to_return(status: 401, body: JSON.generate(cloudflare_error_body("bad token")))

    err = assert_raises(Cloudflare::Email::AuthenticationError) do
      make_client.send(from: "a@b.com", to: "c@d.com", subject: "x", text: "y")
    end
    assert_equal 401, err.status
    assert_match(/bad token/, err.message)
  end

  def test_422_raises_validation_error
    stub_request(:post, send_endpoint)
      .to_return(status: 422, body: JSON.generate(cloudflare_error_body("bad domain")))

    assert_raises(Cloudflare::Email::ValidationError) do
      make_client.send(from: "a@b.com", to: "c@d.com", subject: "x", text: "y")
    end
  end

  def test_429_retries_then_succeeds
    stub_request(:post, send_endpoint)
      .to_return(
        { status: 429, body: JSON.generate(cloudflare_error_body("rate limited")) },
        { status: 200, body: JSON.generate(cloudflare_success_body) },
      )

    response = make_client(retries: 2).send(
      from: "a@b.com", to: "c@d.com", subject: "x", text: "y",
    )
    assert response.success?
  end

  def test_5xx_retries_then_fails_when_exhausted
    stub_request(:post, send_endpoint)
      .to_return(status: 503, body: JSON.generate(cloudflare_error_body("upstream down")))

    assert_raises(Cloudflare::Email::ServerError) do
      make_client(retries: 1).send(
        from: "a@b.com", to: "c@d.com", subject: "x", text: "y",
      )
    end
  end

  def test_network_error_retries
    stub_request(:post, send_endpoint)
      .to_raise(Errno::ECONNRESET)
      .then.to_return(status: 200, body: JSON.generate(cloudflare_success_body))

    response = make_client(retries: 1).send(
      from: "a@b.com", to: "c@d.com", subject: "x", text: "y",
    )
    assert response.success?
  end

  def test_invalid_json_response_handled_gracefully
    stub_request(:post, send_endpoint)
      .to_return(status: 500, body: "<html>oh no</html>")

    err = assert_raises(Cloudflare::Email::ServerError) do
      make_client.send(from: "a@b.com", to: "c@d.com", subject: "x", text: "y")
    end
    assert_match(/oh no|html/i, err.message)
  end
end
