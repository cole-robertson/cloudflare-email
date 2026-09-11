# Get email working in your Rails app

This guide takes you from your first outgoing email to receiving replies and
tracking deliveries. Start with sending and add the other pieces as needed.
For a mailbox app, follow all four parts. **SQLite is supported throughout.**

You will need an existing Rails app, a Cloudflare account, and a domain you can
configure in Cloudflare. Use Ruby 3.2+ and a patched supported Rails release:
tested floors are 7.2.3.2, 8.0.5.1 and 8.1.3.1. Rails 8 requires Ruby 3.3+.
Ruby 4 is tested with Rails 8.1. Plain Ruby users can use the
[standalone client](../README.md#plain-ruby) instead.

Example addresses below use `mail.example.com` for sending and
`in.example.com` for receiving. Replace them with subdomains you own. They do
not need to be the same domain as your Rails application's web address.

## 1. Send your first email

### Install the current code

The new features are in the unreleased 0.2.0 code. RubyGems currently serves
0.1.0. Add this reviewed commit to your app's `Gemfile`:

```ruby
gem "cloudflare-email",
  git: "https://github.com/cole-robertson/cloudflare-email.git",
  ref: "661cd2f483973c0f3e0cd4aa091562b009300419"
```

```sh
bundle install
bin/rails generate cloudflare:email:install --no-inbound
```

The generator creates an initializer that chooses `:cloudflare` as your
ActionMailer delivery method. The `--no-inbound` option keeps this first step
focused on sending; you can add receiving below.

### Connect your sending domain

In Cloudflare, open **Compute → Email Service → Email Sending** and onboard
your sending domain. Complete Cloudflare's DNS instructions and wait for domain
verification. A dedicated subdomain helps keep an existing mail provider's apex
configuration separate. Do not replace existing apex mail records casually.

Create an account-scoped token with permission to send email. Add these variables
to the environment where Rails runs, or use the equivalent Rails credentials:

```sh
export CLOUDFLARE_ACCOUNT_ID=your-account-id
export CLOUDFLARE_API_TOKEN=your-email-sending-token
```

Rails credentials use `cloudflare.account_id` and `cloudflare.api_token`.
Nonempty Rails credentials take precedence over environment variables. Keep
real tokens out of committed files. Restart Rails after changing configuration.

### Check the setup and send

```sh
bin/rails cloudflare:email:doctor
FROM=hello@mail.example.com TO=you@example.net bin/rails cloudflare:email:send_test
```

Use a destination inbox you control. `doctor` checks configuration and available
read access; the second command actually sends mail. Confirm that it arrives,
including checking spam. A diagnostics success alone does not prove delivery.

### Use your regular mailers

```ruby
# app/mailers/hello_mailer.rb
class HelloMailer < ApplicationMailer
  def hello(address)
    mail(from: "hello@mail.example.com", to: address, subject: "Hello from Rails") do |format|
      format.text { render plain: "Your email integration is working." }
    end
  end
end
```

From `bin/rails console`:

```ruby
HelloMailer.hello("you@example.net").deliver_now
```

Your existing HTML templates, multipart messages, attachments and cc/bcc work
through ActionMailer. Use `deliver_later` with your app's job backend for ordinary
background delivery. For saved send history and protection against ambiguous
resends, use the outbox in part 3. Do not send the same message through both paths.

## 2. Receive email and replies

Incoming email follows this path:

```text
Sender → Cloudflare Email Routing → Email Worker → Rails ActionMailbox → your app
```

The Worker is a small program that forwards the email to Rails and signs it so
Rails can verify the forwarding request. The installer supplies its code.

### Install receiving support

```sh
bin/rails generate cloudflare:email:install
bin/rails db:migrate
```

Follow the interactive prompts to install ActionMailbox and the default mailbox.
If you already have custom mailbox routing or initializer changes, inspect the
generator's overwrite prompts before accepting. The generated default mailbox
only logs receipt; you will add your product's processing logic.

Save the generated shared secret as `cloudflare.ingress_secret` in Rails
credentials or `CLOUDFLARE_INGRESS_SECRET`. The deploy task copies that secret to
the Worker. Use a separate deployment token as `cloudflare.management_token` or
`CLOUDFLARE_MANAGEMENT_TOKEN`; [the permission table](../README.md#observability-and-permissions)
lists the scopes needed for Worker deployment and routing.

### Connect the receiving address

In Cloudflare **Email Routing → your apex domain → Settings → Subdomains**, add
your receiving subdomain, such as `in.example.com`, and finish its DNS setup.
This is separate from verifying the sending domain.

Deploy Rails with ActionMailbox storage and workers configured. Then run these
commands in an environment with production configuration and deployment credentials:

```sh
RAILS_ENV=production bin/rails cloudflare:email:deploy_worker URL=https://app.example.com/rails/action_mailbox/cloudflare/inbound_emails
RAILS_ENV=production bin/rails cloudflare:email:provision_route ADDRESS=support@in.example.com
```

The first command deploys the Worker; the second routes the address to it.
Send a real test email to `support@in.example.com`, then check the ActionMailbox
record and processing job. A web request accepted by Rails means storage worked;
the mailbox job can still need attention.

### Read the message in your mailbox

Inside the generated `MainMailbox#process`, these values are available:

```ruby
envelope = Cloudflare::Email::Envelope.for(inbound_email)
receiving_address = envelope&.fetch("to")
subject = mail.subject
text = mail.text_part&.body&.decoded || (mail.body.decoded unless mail.multipart?)
attachments = mail.attachments
raw_message = inbound_email.raw_email.download
```

Save or process those values using your application's models. For mailbox or
tenant selection, use `receiving_address`, which comes from the authenticated
SMTP envelope. MIME `To`/`Cc` headers may differ, especially for Bcc. The envelope
can be absent for records from another ingress; handle that case explicitly.
Treat message contents and attachments as untrusted input when displaying them.

To direct replies to this address, add `reply_to: "support@in.example.com"` to
your mailer's `mail(...)` call. For conversation matching, save the returned
provider message ID and compare reply headers within your application's mailbox
scope. The outbox saves this ID for you. See [thread correlation](thread-correlation.md).

### Receive into a local Rails server

Install `cloudflared`, configure development credentials and a separate development
receiving route, then start Rails. In another terminal:

```sh
bin/rails cloudflare:email:deploy_worker
bin/rails cloudflare:email:dev
```

The first command creates the development Worker; the second points it at a
temporary tunnel to your local Rails server on port 3000. Keep the tunnel running
while testing and stop it with Ctrl-C. Set `PORT=...` if Rails uses another port.
The task checks that Rails has the ingress-only guard; restart Rails if asked.
Use development test data. The tunnel URL is temporary and does not provide an
offline mailbox when your local server is stopped.

## 3. Add the durable outbox with SQLite

An outbox saves the exact message before sending it. Background jobs reference
that saved operation instead of re-rendering and resending mail on every retry.
This is useful for compose, replies, invoices and approved drafts.

If your Rails app already uses SQLite, keep its database configuration. Run:

```sh
bin/rails generate cloudflare:email:tracking
bin/rails generate cloudflare:email:outbox
bin/rails db:migrate
```

These add the receipt and delivery tables plus opt-in initializers. Skip a
generator whose migration you already installed. Configure a durable ActiveJob
backend and run a worker that processes the `mailers` queue; the gem does not
install the backend for you.

Try this from Rails console, outside an existing database transaction:

```ruby
account_id = Cloudflare::Email::Credentials.account_id
operation = Cloudflare::Email::ActiveRecord::Outbox.prepare_mail(
  account_id: account_id,
  operation_key: "getting-started:hello:1",
  mail: HelloMailer.hello("you@example.net").message,
)
Cloudflare::Email::SendJob.perform_later(account_id, operation.operation_key)
```

The operation key identifies **one intended send** in your account. Save it with
your product record. For a genuinely new message use a new key; for a job retry
reuse the saved identity. Do not re-render a mailer and call `prepare_mail` as
your retry mechanism: generated MIME headers can change, causing a snapshot conflict.

In an application transaction, prepare the operation alongside your business
record, then enqueue only after the outer transaction commits. The detailed
[outbox guide](outbox.md#prepare-once-dispatch-after-commit) shows that pattern.

After the worker runs, inspect the result:

```ruby
operation.reload.state
operation.provider_message_id
operation.outbound_recipients.pluck(:recipient, :acceptance_state, :state)
```

`accepted` means all recipients have provider acceptance evidence; `partial`
means only some do. Neither promises that a human received or read the message.
`unknown` or a stuck `sending` operation needs investigation, not a new send key
as a shortcut. See [states and recovery](outbox.md#states-and-retries).

## 4. Track delivery, bounces and complaints

Cloudflare sends later delivery updates through a Queue. You configure that
Queue and its Email Sending subscription once; your app polls it regularly.
Follow [the provisioning steps](delivery-events.md#provision-once), including an
HTTP pull consumer, retries and a dead-letter queue for repeatedly failing events.

Add a separate queue token and queue ID to your Rails environment:

```sh
export CLOUDFLARE_QUEUES_TOKEN=your-queues-read-write-token
export CLOUDFLARE_EVENT_QUEUE_ID=your-queue-id
```

With the outbox installed, configure this initializer:

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

Restart Rails and poll a batch:

```sh
bin/rails cloudflare:email:consume_events
```

This command processes **one batch and exits**. Schedule it repeatedly using
your application's scheduler. Also schedule receipt replay for recovery:

```sh
bin/rails cloudflare:email:replay_events
```

The gem saves receipts before acknowledgement, handles duplicates, and matches
updates to the account, provider message ID and recipient. If an event arrives
before the send result is saved, it stays available for replay. Recipient state
then reflects delivered, deferred, bounced, failed, rejected or complained events.
Your app still decides what those outcomes mean for its UI and future sending.

For custom product updates, use the [transactional callbacks](outbox.md#recover-dispatch-and-application-projections).
If you only want events and have your own delivery models, use the lower-level
[durable receipt adapter](delivery-events.md#durable-rails-receipts).

## Before relying on it

Send to an external inbox you control, reply back, verify stored attachments,
and confirm a real queue event updates the intended recipient. Keep a durable
job worker running and schedule recovery of `prepared` operations that might
have committed before enqueueing. Monitor stuck operations and failed mailbox jobs.

Protect stored MIME and attachments, choose retention and backup policies, and
set proxy/server request limits. The default incoming raw message limit is
25 MiB; set the same positive `MAX_EMAIL_BYTES` on Rails and the Worker if you
override it. Cloudflare has separate [outgoing size and recipient limits](https://developers.cloudflare.com/email-service/platform/limits/).

Use [troubleshooting](troubleshooting.md) when something does not arrive,
[the feature overview](features.md) to explore more, and
[the upgrade guide](upgrading-0.2.md) for an existing 0.1 installation.
