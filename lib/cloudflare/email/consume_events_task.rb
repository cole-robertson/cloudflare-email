require "cloudflare/email/task_base"
require "cloudflare/email/event_consumer"

module Cloudflare
  module Email
    class ConsumeEventsTask < TaskBase
      def run
        handler = opts[:handler]
        raise ConfigurationError, "configure config.x.cloudflare_email.event_handler with a callable" unless handler.respond_to?(:call)

        consumer = EventConsumer.new(
          account_id: account_id,
          api_token: require_value!(credential(:queues_token), "cloudflare.queues_token / CLOUDFLARE_QUEUES_TOKEN"),
          queue_id: require_value!(credential(:event_queue_id), "cloudflare.event_queue_id / CLOUDFLARE_EVENT_QUEUE_ID"),
          domains: opts[:domains],
        )
        count = consumer.poll(batch_size: opts.fetch(:batch_size, 5), &handler.method(:call))
        say "  Processed and acknowledged #{count} delivery event(s)."
      end
    end
  end
end
