# Cloudflare Email

Send and receive email in Ruby and Rails through [Cloudflare Email Service](https://developers.cloudflare.com/email-service/).

Use your existing Rails mailers, receive messages through Action Mailbox, and add
persistent inboxes with [Mailbox Kit](mailbox-kit/README.md). SQLite is supported.
Database tenancy and the management UI are optional.

## Install

```ruby
gem "cloudflare-email", "~> 0.4.0"
```

Mailbox Kit installs automatically. If you use another email provider, you can
[use Mailbox Kit on its own](mailbox-kit/README.md).

Requires Ruby 3.2+; Rails integrations support Rails 7.2–8.1.
Use a current patch release. Plain Ruby sending does not require Rails or a database.

## Send from Rails

```sh
bundle install
bin/rails generate cloudflare:email:install --no-inbound
```

[Verify a sending domain in Cloudflare](https://developers.cloudflare.com/email-service/configuration/domains/)
and add your account ID and sending token:

```sh
export CLOUDFLARE_ACCOUNT_ID=your-account-id
export CLOUDFLARE_API_TOKEN=your-email-sending-token
```

Your regular mailers can now send through Cloudflare:

```ruby
class HelloMailer < ApplicationMailer
  def hello(address)
    mail(from: "hello@mail.example.com", to: address, subject: "Hello") do |format|
      format.text { render plain: "Hello from Rails!" }
    end
  end
end

HelloMailer.hello("you@example.net").deliver_now
```

HTML templates, attachments, multipart messages, cc/bcc, and reply headers work
through Action Mailer. Follow the [Rails setup guide](docs/getting-started.md)
for receiving and delivery tracking.

## Receive email

The included Worker stores incoming email at Cloudflare and retries delivery
while Rails is unavailable. Rails verifies each request and stores the original
email through Action Mailbox.

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/cole-robertson/cloudflare-email/tree/main/templates/deploy-to-cloudflare)

[Prepare Rails and deploy the Worker](templates/deploy-to-cloudflare/README.md),
then connect your receiving address in Cloudflare Email Routing.

## Build an inbox

The [mailbox guide](docs/mailboxes.md) walks through creating inboxes and aliases,
receiving mail, marking it read, archiving it, and sending replies.

Mount the optional [management UI](docs/management-engine.md) to manage mailboxes
and read messages using your app's login and permissions. It is server-rendered
and needs no frontend build.

For a runnable SQLite example, clone the
[hello-world Rails app](https://github.com/cole-robertson/cloudflare-email-rails-starter).

## Plain Ruby

```ruby
require "cloudflare-email"

client = Cloudflare::Email::Client.new(
  account_id: ENV.fetch("CLOUDFLARE_ACCOUNT_ID"),
  api_token: ENV.fetch("CLOUDFLARE_API_TOKEN"),
)

response = client.send(
  from: "hello@mail.example.com",
  to: "you@example.net",
  subject: "Hello",
  text: "Hello from Ruby!",
)
response.message_id
response.accepted?
```

Acceptance is the start of delivery. Use [delivery events](docs/delivery-events.md)
to track delivered messages, bounces, and complaints.
See the [Ruby API reference](docs/reference.md) for attachments, raw MIME, and configuration.

## Guides

| Task | Guide |
| --- | --- |
| Set up sending, receiving, and tracking | [Rails quickstart](docs/getting-started.md) |
| Explore the available features | [Feature list](docs/features.md) |
| Create inboxes and aliases | [Mailboxes](docs/mailboxes.md) |
| Add mailbox administration | [Management UI](docs/management-engine.md) |
| Configure addresses and customer subdomains | [Cloudflare domain setup](templates/worker/docs/domain-setup.md) |
| Save outgoing messages and safely retry jobs | [Outbox](docs/outbox.md) |
| Track delivery and bounces | [Delivery events](docs/delivery-events.md) |
| Use separate SQLite databases | [Database tenancy](docs/activerecord-tenanted.md) |
| Connect a custom receiving endpoint | [Custom ingress](docs/custom-ingress.md) |
| Diagnose missing mail | [Troubleshooting](docs/troubleshooting.md) |
| Configure the client and command-line tasks | [Reference](docs/reference.md) |

[Security](SECURITY.md) · [Contributing](CONTRIBUTING.md) · [MIT license](LICENSE.txt)
