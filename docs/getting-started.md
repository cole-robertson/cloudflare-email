# Set up email in Rails

This guide covers sending, receiving, and delivery tracking. For persistent
inboxes and a management UI, continue with [mailboxes](mailboxes.md).
SQLite works throughout.

You need Rails 7.2–8.1, a Cloudflare account, and a domain you control.
These examples use `mail.example.com` for sending and `in.example.com` for receiving.

## 1. Install

Add to your Gemfile:

```ruby
gem "cloudflare-email", "~> 0.4.0"
```

```sh
bundle install
bin/rails generate cloudflare:email:install
bin/rails db:migrate
```

Follow the prompts to install Action Mailbox and the default mailbox.
The generator also configures Action Mailer and copies the Worker template.
For a send-only app, use `--no-inbound` and skip the receiving steps below.

## 2. Send your first email

In Cloudflare, open **Compute → Email Service → Email Sending**, add
`mail.example.com`, and complete its DNS verification. A sending subdomain lets
you keep your existing domain's mail provider.

Create a token with Email Sending permission and set:

```sh
export CLOUDFLARE_ACCOUNT_ID=your-account-id
export CLOUDFLARE_API_TOKEN=your-email-sending-token
```

Alternatively, use Rails credentials `cloudflare.account_id` and
`cloudflare.api_token`. Nonempty Rails credentials take precedence.
Restart Rails after changing configuration.

Check the configuration and send to an inbox you control:

```sh
bin/rails cloudflare:email:doctor
FROM=hello@mail.example.com TO=you@example.net bin/rails cloudflare:email:send_test
```

Check the destination inbox and spam folder. `doctor` checks configuration;
`send_test` sends the message.

### Use your mailers

```ruby
# app/mailers/hello_mailer.rb
class HelloMailer < ApplicationMailer
  def hello(address)
    mail(from: "hello@mail.example.com", to: address, subject: "Hello from Rails") do |format|
      format.text { render plain: "Your email integration is working." }
    end
  end
end

HelloMailer.hello("you@example.net").deliver_now
```

Use `deliver_later` with your app's job backend for background sending.
HTML templates, attachments, multipart messages, and cc/bcc work through Action Mailer.

## 3. Receive email

```text
Sender → Cloudflare Email Routing → Worker → Rails Action Mailbox → your handler
```

The Worker saves incoming email at Cloudflare and retries delivery while Rails
is unavailable.

### Deploy the Worker

Save the generated secret as `cloudflare.ingress_secret` in Rails credentials
or `CLOUDFLARE_INGRESS_SECRET`. Deploy Rails with Active Storage and a running
job worker, then follow the [Deploy to Cloudflare guide](../templates/deploy-to-cloudflare/README.md).

The deployment form asks for:

- **RAILS_INGRESS_URL:** `https://app.example.com/rails/action_mailbox/cloudflare/inbound_emails`
- **INGRESS_SECRET:** the same secret configured in Rails

### Connect an address

In Cloudflare Email Routing, configure `in.example.com` and its receiving DNS
records. Create a rule for `support@in.example.com` with **Send to a Worker**,
selecting the deployed Worker.

Sending-domain verification and receiving routes are separate.
For many addresses or customer subdomains, use the [domain setup guide](../templates/worker/docs/domain-setup.md).

Send a test email to `support@in.example.com`. Confirm Rails stores it and
the mailbox job finishes.

### Process the email

Add your application logic to the generated `MainMailbox#process`:

```ruby
envelope = Cloudflare::Email::Envelope.for(inbound_email)
receiving_address = envelope&.fetch("to")
subject = mail.subject
text = mail.text_part&.body&.decoded || (mail.body.decoded unless mail.multipart?)
attachments = mail.attachments
raw_message = inbound_email.raw_email.download
```

Use the verified `receiving_address` for mailbox or organization lookup.
The MIME `To` header can differ, especially for Bcc. Treat message contents
and attachments as untrusted input.

Set `reply_to: "support@in.example.com"` in outgoing mail to receive replies here.
See [reply matching](thread-correlation.md) for conversations.

### Test with a local Rails server

Install `cloudflared`, start Rails, and configure a separate development address.
Then run:

```sh
INBOUND_DELIVERY_MODE=direct bin/rails cloudflare:email:deploy_worker
bin/rails cloudflare:email:dev
```

These commands need a [Worker management token](reference.md#observability-and-permissions).
Keep the tunnel running while testing. It uses port 3000 by default;
set `PORT=...` for another port. Direct mode does not retain mail while
your local server is stopped.

## 4. Save outgoing messages

The outbox saves a message before sending, tracks each recipient, and protects
against accidental resends after a timeout.

```sh
bin/rails generate cloudflare:email:tracking
bin/rails generate cloudflare:email:outbox
bin/rails db:migrate
```

If you are setting up [managed mailboxes](mailboxes.md), use that generator
instead—it includes both of these.

With a job worker processing the `mailers` queue, try this from Rails console:

```ruby
account_id = Cloudflare::Email::Credentials.account_id
operation = Cloudflare::Email::ActiveRecord::Outbox.prepare_mail(
  account_id: account_id,
  operation_key: "hello:1",
  mail: HelloMailer.hello("you@example.net").message,
)
Cloudflare::Email::SendJob.perform_later(account_id, operation.operation_key)
```

Use one operation key per intended send. For retries, dispatch the saved
operation rather than rendering and sending the mailer again.
In application transactions, enqueue after commit.

Inspect the result:

```ruby
operation.reload.state
operation.provider_message_id
operation.outbound_recipients.pluck(:recipient, :acceptance_state, :state)
```

See the [outbox guide](outbox.md) for application transactions, callbacks,
and recovery of uncertain sends.

## 5. Track delivery

Create an outbound Cloudflare Queue and Email Sending subscription using the
[delivery-event setup](delivery-events.md#provision-once). This is a separate
queue from the inbound Worker queue.

Set:

```sh
export CLOUDFLARE_QUEUES_TOKEN=your-queues-read-write-token
export CLOUDFLARE_EVENT_QUEUE_ID=your-queue-id
```

With the outbox installed, configure:

```ruby
# config/initializers/cloudflare_delivery_events.rb
require "cloudflare/email/active_record"

Rails.application.configure do
  config.x.cloudflare_email.event_domains = ["mail.example.com"]
  config.x.cloudflare_email.event_handler = ->(event) {
    Cloudflare::Email::ActiveRecord::DeliveryEvents.record(event)
  }
end
```

Restart Rails and run:

```sh
bin/rails cloudflare:email:consume_events
bin/rails cloudflare:email:replay_events
```

Each command runs once and exits; schedule both to run regularly.
Receipts are saved before acknowledgement and matched to the message's
recipients. Delivery states include delivered, deferred, bounced, failed,
rejected, and complained.

## Check your setup

Send to an external inbox, reply back, check the stored attachment, and confirm
a delivery event updates the intended recipient. Keep Rails jobs and event
polling running, and monitor failed jobs and the Worker's pending mail.

Next: [create inboxes](mailboxes.md), [add the management UI](management-engine.md),
or [troubleshoot missing mail](troubleshooting.md).
