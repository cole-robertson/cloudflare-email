# Delivery events

Cloudflare Email Sending can publish outbound lifecycle events to Queues. This is separate from inbound Email Routing and the ActionMailbox ingress.

## Provision once

1. Create a dedicated Cloudflare Queue for your application's sending events.
2. In that queue's **Subscriptions** tab, subscribe to Email Sending events for your verified sending domain. Subscriptions are domain-specific; add another for each sending domain you need.
3. Select delivered, deferred, bounced, failed, rejected, and complained events.
4. Enable **HTTP pull** as the queue consumer. Do not also attach a Worker push consumer.
5. Configure queue retries and a dead-letter queue so failed or unsupported events can be investigated instead of disappearing after retry exhaustion.
6. Create an account-scoped **Queues Read + Write** token (dashboard Queues Edit). Writing is necessary to acknowledge messages.

These are explicit Cloudflare setup steps, not actions performed by installing this gem. See [subscription management](https://developers.cloudflare.com/queues/event-subscriptions/manage-event-subscriptions/) and [HTTP pull consumers](https://developers.cloudflare.com/queues/configuration/pull-consumers/).

## Rails setup

Add credentials:

```yaml
cloudflare:
  account_id: your-account-id
  queues_token: your-queues-read-write-token
  event_queue_id: your-queue-id
```

Environment alternatives are `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_QUEUES_TOKEN`, and `CLOUDFLARE_EVENT_QUEUE_ID`. Queue consumption uses its own token; it does not use the management-token fallback.

Configure a callable application handler:

```ruby
# config/initializers/cloudflare_delivery_events.rb
Rails.application.configure do
  config.x.cloudflare_email.event_domains = ["mail.example.com"]
  config.x.cloudflare_email.event_handler = ->(event) {
    DeliveryEventProcessor.call(event)
  }
end
```

`DeliveryEventProcessor` is application code you provide. Persist the event and related delivery state transactionally before returning. Give the stored `event_id` a unique database index and make a repeated event a successful no-op. Do not merely enqueue a non-durable job and assume it has finished.

Poll a single batch:

```sh
bin/rails cloudflare:email:consume_events
BATCH_SIZE=20 bin/rails cloudflare:email:consume_events
```

Run the task from your existing scheduler, or invoke `EventConsumer#poll` from a recurring job. It short-polls once and exits; an empty queue is a successful result. No handler means an error before any queue request, not automatic discard.

For more control, use the API directly:

```ruby
consumer = Cloudflare::Email::EventConsumer.new(
  account_id: Cloudflare::Email::Credentials.account_id,
  api_token: Cloudflare::Email::Credentials.fetch(:queues_token),
  queue_id: Cloudflare::Email::Credentials.fetch(:event_queue_id),
  domains: ["mail.example.com"],
)

count = consumer.poll(batch_size: 5, visibility_timeout_ms: 300_000) do |event|
  DeliveryEventProcessor.call(event)
end
```

The same API works in plain Ruby with explicit credentials.

## Event data

| Method | Meaning |
|---|---|
| `event_id` | Durable application deduplication key |
| `message_id` | Cloudflare message ID for correlation with the send response |
| `status` | delivered, deferred, bounced, failed, rejected, complained |
| `known?` | Whether status is one of those six current types |
| `terminal?` | Cloudflare's terminal flag; not a guarantee no later complaint arrives |
| `sender`, `recipient` | Addresses from the event |
| `account_id`, `domain` | Event source, checked against consumer configuration |
| `occurred_at` | Original event timestamp string |
| `delivery`, `bounce`, `rejection`, `failure`, `complaint` | Detail hashes |
| `raw`, `payload`, `type` | Original provider data |

Record outcomes per message **and recipient**. A delivery event means the recipient's server accepted the message, not that the person read it. Use bounce/complaint events to maintain your application's recipient eligibility and unsubscribe state. Cloudflare's own suppression behavior remains controlled by Cloudflare; the consumer does not automatically edit provider suppression lists or your database.

Events can be duplicated or arrive out of order. Do not blindly overwrite a newer terminal state with an older deferred event. Decide how your application handles a complaint after delivery. Provider IDs may be absent from older send responses; retain event data even when an application record cannot yet be found.

## Processing guarantees

For each message, the consumer decodes the body, validates the event, invokes your handler, and then acknowledges its lease. Email Sending subscriptions can return plain JSON strings with `CF-Content-Type: json`; the consumer also accepts base64-encoded JSON for that content type. `bytes` bodies contain base64-encoded JSON, while `text` bodies contain JSON directly. Invalid bodies and events remain unacknowledged.

- A handler that returns normally counts as successful, even if its return value is `false` or `nil`. **Raise** to prevent acknowledgement.
- A parse error, mismatched account/domain, handler exception, or acknowledgement failure stops the batch. Previously acknowledged messages remain acknowledged; the current and remaining leases become available after the visibility timeout.
- If the handler commits and acknowledgement fails, the event can be processed again. This is why the handler needs durable idempotency.
- Automatic HTTP retries are disabled for queue calls. Your scheduler can retry the next poll.
- The default batch size is 5 (max 100); the default visibility window is five minutes. Choose a window longer than the **whole batch's** worst-case processing time, up to Cloudflare's 12-hour maximum.
- Unknown future status names in schema version 1 are passed through with `known? == false`. Decide whether to store or raise. Unsupported schema versions are rejected and left unacknowledged.
- Configure dead-letter retention/alerts. Repeated failure eventually exhausts the queue's retry policy.

The `cloudflare_email.delivery_event` notification wraps handler execution with event ID, message ID, and status. It does not mean acknowledgement succeeded. Monitor task/job failures as well.

Source schemas: [Email Sending event subscriptions](https://developers.cloudflare.com/email-service/platform/event-subscriptions/), [pull API](https://developers.cloudflare.com/api/resources/queues/subresources/messages/methods/pull/), [ack API](https://developers.cloudflare.com/api/resources/queues/subresources/messages/methods/ack/).
