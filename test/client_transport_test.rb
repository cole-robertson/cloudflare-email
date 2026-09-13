require "test_helper"
require "socket"
require "stringio"
require "zlib"

class ClientTransportTest < Minitest::Test
  def send_message(client)
    client.send(from: "sender@example.com", to: "recipient@example.net", subject: "Hello", text: "Body")
  end

  # Bypass WebMock's real-request buffering to exercise Net::HTTP streaming.
  def with_server(&handler)
    WebMock.disable!
    server = TCPServer.new("127.0.0.1", 0)
    @requests = Queue.new
    @closed = Queue.new
    thread = Thread.new do
      loop do
        socket = server.accept
        begin
          first = socket.gets
          headers = {}
          while (line = socket.gets) && line != "\r\n"
            name, value = line.split(":", 2)
            headers[name.downcase] = value.strip
          end
          socket.read(headers.fetch("content-length", "0").to_i)
          @requests << first
          handler.call(socket)
        rescue Errno::EPIPE, Errno::ECONNRESET
          @closed << true
        ensure
          socket.close
        end
      end
    end
    yield_url = "http://127.0.0.1:#{server.addr[1]}"
    yield_url
  ensure
    # The server must remain alive during the caller's request.
    @transport_server = server
    @transport_thread = thread
  end

  def teardown
    @transport_thread&.kill
    @transport_thread&.join
    @transport_server&.close
    WebMock.enable!
    super
  end

  def chunk(socket, body)
    socket.write("#{body.bytesize.to_s(16)}\r\n#{body}\r\n")
  end

  def test_chunked_response_limit_interrupts_and_closes_without_retry
    url = with_server do |socket|
      socket.write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
      chunk(socket, "a" * 40)
      chunk(socket, "b" * 40)
      @closed << socket.read(1).nil?
    end
    error = assert_raises(Cloudflare::Email::NetworkError) do
      send_message(make_client(base_url: url, max_response_bytes: 60, retries: 3))
    end
    assert_match(/outcome is unknown/, error.message)
    assert_nil error.cause
    assert Timeout.timeout(2) { @closed.pop }
    assert_equal 1, @requests.size
  end

  def test_total_deadline_stops_a_stream_that_never_hits_read_timeout
    url = with_server do |socket|
      socket.write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
      200.times do
        chunk(socket, " ")
        sleep 0.02
      end
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Cloudflare::Email::NetworkError) do
      send_message(make_client(base_url: url, timeout: 1, total_timeout: 0.15, retries: 3))
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
    assert_equal 1, @requests.size
    assert Timeout.timeout(2) { @closed.pop }
  end

  def test_compressed_expansion_is_bounded_after_decompression
    buffer = StringIO.new
    gzip = Zlib::GzipWriter.new(buffer)
    gzip.write("x" * 100_000)
    gzip.close
    compressed = buffer.string
    assert_operator compressed.bytesize, :<, 500
    url = with_server do |socket|
      socket.write("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: #{compressed.bytesize}\r\n\r\n")
      socket.write(compressed)
    end
    assert_raises(Cloudflare::Email::NetworkError) do
      send_message(make_client(base_url: url, max_response_bytes: 500))
    end
    assert_equal 1, @requests.size
  end

  def test_error_responses_are_bounded_too
    url = with_server do |socket|
      socket.write("HTTP/1.1 503 Unavailable\r\nContent-Length: 100\r\n\r\n#{'x' * 100}")
    end
    assert_raises(Cloudflare::Email::NetworkError) do
      send_message(make_client(base_url: url, max_response_bytes: 50, retries: 3))
    end
    assert_equal 1, @requests.size
  end

  def test_exact_byte_budget_accepts_valid_response
    body = JSON.generate(cloudflare_success_body)
    url = with_server do |socket|
      socket.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
    end
    assert send_message(make_client(base_url: url, max_response_bytes: body.bytesize)).success?
  end

  def test_configuration_rejects_unbounded_or_invalid_limits
    [0, -1, nil, "5", Float::INFINITY, Float::NAN].each do |value|
      [:timeout, :total_timeout].each do |option|
        assert_raises(Cloudflare::Email::ConfigurationError) { make_client(**{ option => value }) }
      end
    end
    [0, -1, 1.5, nil, "5"].each do |value|
      assert_raises(Cloudflare::Email::ConfigurationError) { make_client(max_response_bytes: value) }
    end
  end

  def queue_message
    JSON.parse(File.read(File.join(__dir__, "fixtures/email_sending_queue_message.json"))).merge("lease_id" => "lease-123")
  end

  def test_ack_timeout_leaves_completed_handler_replayable_without_retry
    pull_body = JSON.generate("success" => true, "result" => { "messages" => [queue_message] })
    url = with_server do |socket|
      if @requests.size == 1
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: #{pull_body.bytesize}\r\n\r\n#{pull_body}")
      else
        # ACK may have succeeded remotely even though its response is lost.
        sleep 0.3
      end
    end
    consumer = Cloudflare::Email::EventConsumer.new(queue_id: "queue-123", account_id: ACCOUNT_ID,
      api_token: API_TOKEN, base_url: url, total_timeout: 0.1, retries: 3)
    handled = []
    assert_raises(Cloudflare::Email::NetworkError) do
      consumer.poll do |event|
        sleep 0.15 # Application work is deliberately outside the HTTP deadline.
        handled << event.event_id
      end
    end
    assert_equal ["event-123"], handled
    assert_equal 2, @requests.size
    assert_match(%r{/messages/pull}, @requests.pop)
    assert_match(%r{/messages/ack}, @requests.pop)
  end

  def test_maximum_queue_batch_can_exceed_sending_response_budget
    message = queue_message
    event = JSON.parse(message["body"])
    event["payload"]["subject"] = "x" * 20_000
    message["body"] = JSON.generate(event)
    body = JSON.generate("success" => true, "result" => { "messages" => Array.new(100) { message } })
    assert_operator body.bytesize, :>, Cloudflare::Email::Client::DEFAULT_MAX_RESPONSE_BYTES
    base = "https://api.cloudflare.com/client/v4/accounts/#{ACCOUNT_ID}/queues/queue-123/messages"
    stub_request(:post, "#{base}/pull").to_return(body: body)
    ack = stub_request(:post, "#{base}/ack").to_return(body: JSON.generate("success" => true, "result" => { "ackCount" => 1 }))
    consumer = Cloudflare::Email::EventConsumer.new(queue_id: "queue-123", account_id: ACCOUNT_ID, api_token: API_TOKEN)
    assert_equal 100, consumer.poll(batch_size: 100) { |event| assert_equal "event-123", event.event_id }
    assert_requested ack, times: 100
  end

  def test_ack_uses_small_budget_and_failure_does_not_repeat_handler_or_ack
    base = "https://api.cloudflare.com/client/v4/accounts/#{ACCOUNT_ID}/queues/queue-123/messages"
    stub_request(:post, "#{base}/pull").to_return(body: JSON.generate("success" => true, "result" => { "messages" => [queue_message] }))
    ack = stub_request(:post, "#{base}/ack").to_return(body: "x" * (Cloudflare::Email::Client::DEFAULT_MAX_RESPONSE_BYTES + 1))
    consumer = Cloudflare::Email::EventConsumer.new(queue_id: "queue-123", account_id: ACCOUNT_ID, api_token: API_TOKEN)
    handled = 0
    assert_raises(Cloudflare::Email::NetworkError) { consumer.poll { handled += 1 } }
    assert_equal 1, handled
    assert_requested ack, times: 1
  end

  def test_network_and_malformed_json_errors_do_not_expose_payload_or_cause
    request = stub_request(:post, send_endpoint).to_raise(IOError.new("secret-token secret-body"))
    error = assert_raises(Cloudflare::Email::NetworkError) { send_message(make_client(retries: 3)) }
    refute_match(/secret/, error.full_message)
    assert_nil error.cause
    assert_requested request, times: 1
    stub_request(:post, send_endpoint).to_return(status: 503, body: "secret-body is not JSON")
    error = assert_raises(Cloudflare::Email::ServerError) { send_message(make_client) }
    refute_match(/secret/, error.full_message)
    refute_match(/secret/, error.response.inspect)
    assert_nil error.cause
  end
end
