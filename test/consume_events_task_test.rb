require "test_helper"
require "stringio"
require "cloudflare/email/consume_events_task"

class ConsumeEventsTaskTest < Minitest::Test
  def test_missing_handler_fails_before_consuming
    io = StringIO.new
    assert_equal 1, Cloudflare::Email::ConsumeEventsTask.call(io: io)
    assert_includes io.string, "event_handler"
    assert_not_requested :post, %r{/queues/}
  end

  def test_task_uses_dedicated_credentials_and_handler
    credentials = { account_id: ACCOUNT_ID, queues_token: "queues-token", event_queue_id: "queue-id" }
    consumer = Object.new
    event = Object.new
    received = []
    consumer.define_singleton_method(:poll) do |batch_size:, &block|
      raise "wrong batch size" unless batch_size == 10
      block.call(event)
      1
    end
    factory = lambda do |**options|
      assert_equal ACCOUNT_ID, options[:account_id]
      assert_equal "queues-token", options[:api_token]
      assert_equal "queue-id", options[:queue_id]
      assert_equal ["mail.example.com"], options[:domains]
      consumer
    end
    io = StringIO.new
    Cloudflare::Email::Credentials.stub(:fetch, ->(key) { credentials.fetch(key, "") }) do
      Cloudflare::Email::EventConsumer.stub(:new, factory) do
        assert_equal 0, Cloudflare::Email::ConsumeEventsTask.call(
          io: io, handler: ->(value) { received << value }, domains: ["mail.example.com"], batch_size: 10,
        )
      end
    end
    assert_equal [event], received
    assert_includes io.string, "acknowledged 1"
  end
end
