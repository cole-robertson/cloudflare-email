# cloudflare-email

Ruby client for [Cloudflare Email Service](https://developers.cloudflare.com/email-service/), with an ActionMailer delivery method, an ActionMailbox ingress, a signed forwarding Worker, and an outbound delivery-event consumer.

Version **0.2.0** (release candidate). Ruby 3.2+, Rails 7.1–8.1; Ruby 4.0 is tested with Rails 8.1. Prefer a maintained Ruby/Rails release for new applications. The plain Ruby client uses Ruby's standard libraries plus the Base64 gem. Node is optional: Worker deployment also works through the included Ruby deployer.

## Install and send from Rails

```sh
bundle add cloudflare-email
bin/rails generate cloudflare:email:install --no-inbound
```

Until 0.2.0 is published, use this repository's update branch or a local checkout to try the new features; RubyGems still serves 0.1.0.

Add Rails credentials (encrypted, per environment) or environment variables:

```yaml
cloudflare:
  account_id: your-account-id
  api_token: your-email-sending-token
```

```sh
export CLOUDFLARE_ACCOUNT_ID=your-account-id
export CLOUDFLARE_API_TOKEN=your-email-sending-token
```

The generated initializer uses `Cloudflare::Email::Credentials`: nonempty Rails credentials take precedence, then `CLOUDFLARE_*` environment variables. For an existing 0.1.0 installation, update the initializer manually; see [upgrading](docs/upgrading-0.2.md).

Onboard a sending domain under **Compute → Email Service → Email Sending**. Use a dedicated sending subdomain if the apex already uses another mail provider. Cloudflare's onboarding adds the required bounce MX, SPF, DKIM, and DMARC records for that sending domain. Follow the current [domain configuration](https://developers.cloudflare.com/email-service/configuration/domains/) instructions; do not replace an existing apex SPF record or publish a second one.

Create a token with permission to send for your account, and verify the domain in the dashboard before testing:

```sh
bin/rails cloudflare:email:doctor
FROM=hello@mail.example.com TO=you@example.net bin/rails cloudflare:email:send_test
```

`doctor` checks configuration and available read access. It does not send mail or prove deliverability. `send_test` requires both `FROM` and `TO`.

Standard ActionMailer works:

```ruby
class WelcomeMailer < ApplicationMailer
  def welcome(user)
    mail(from: "hello@mail.example.com", to: user.email, subject: "Welcome") do |format|
      format.text { render plain: "Hello!" }
    end
  end
end

WelcomeMailer.welcome(user).deliver_later
```

Multipart, attachments, cc/bcc, and threading headers are serialized through `send_raw`. Cloudflare still controls final delivery and header acceptance.

## Plain Ruby

```ruby
require "cloudflare-email"

client = Cloudflare::Email::Client.new(
  account_id: ENV.fetch("CLOUDFLARE_ACCOUNT_ID"),
  api_token: ENV.fetch("CLOUDFLARE_API_TOKEN"),
)

response = client.send(
  from: { address: "hello@mail.example.com", name: "Example" },
  to: "you@example.net",
  subject: "Hello",
  text: "Plain body",
  html: "<p>HTML body</p>",
  reply_to: "support@in.example.com",
)
response.message_id             # Provider ID when returned; nil on older responses
response.delivered              # Immediately delivered recipients
response.queued                 # Recipients queued for later delivery
response.permanent_bounces      # Recipients that permanently bounced
response.suppressed_recipients  # Recipients dropped by suppression policy
```

`to` may be omitted for cc-only or bcc-only mail. Addresses accept strings or `{ address:, name: }` hashes. Attachments use Cloudflare's `content` (base64), `filename`, `type`, `disposition`, and optional `content_id` fields. For full MIME control, use `client.send_raw(from:, recipients:, mime_message:)`.

An HTTP success does not mean every recipient received the message. Inspect the recipient outcome arrays and use [delivery events](docs/delivery-events.md) for later results. The current API reference includes message IDs and suppressed recipients; older responses remain supported.

Cloudflare currently limits ordinary sends to 50 recipients and 5 MiB including attachments; verified destination addresses have a 25 MiB allowance. These limits are enforced by Cloudflare. See [limits](https://developers.cloudflare.com/email-service/platform/limits/) and the [header allowlist](https://developers.cloudflare.com/email-service/reference/headers/).

## Receive through ActionMailbox

Cloudflare Email Routing invokes an Email Worker. The bundled Worker forwards unchanged raw MIME to Rails with a versioned HMAC-SHA256 signature covering the timestamp, SMTP envelope, and body. Rails verifies the signature and a five-minute timestamp window before storing the message in ActionMailbox.

```sh
bin/rails generate cloudflare:email:install
```

The interactive installer offers ActionMailbox installation/migrations and a default `MainMailbox`, copies the Worker, and configures ingress in development and production. Add `--all-envs` to include test; configure custom staging environments explicitly. Send-only apps do not need ActionMailbox.

Add the generated ingress secret and an optional management token:

```yaml
cloudflare:
  account_id: your-account-id
  api_token: your-runtime-send-token
  management_token: your-deployment-token
  ingress_secret: the-generated-random-secret
```

Equivalent environment names are `CLOUDFLARE_MANAGEMENT_TOKEN` and `CLOUDFLARE_INGRESS_SECRET`. Keep management credentials in the deployment environment rather than the running application. Credentials stored in the application's Rails credentials are accessible to that application; this gem is not a secret-isolation boundary.

1. Add the receiving subdomain, for example `in.example.com`, in **Email Routing → apex domain → Settings → Subdomains**. This is a separate onboarding step from sending.
2. Deploy the environment's Worker and create its route:

```sh
RAILS_ENV=production bin/rails cloudflare:email:deploy_worker URL=https://app.example.com/rails/action_mailbox/cloudflare/inbound_emails
RAILS_ENV=production bin/rails cloudflare:email:provision_route ADDRESS=support@in.example.com
```

Subdomain provisioning checks configured DNS before creating a rule. It never enables the parent apex on behalf of a subdomain. A missing setup or permission fails with instructions. DNS records alone do not prove propagation or live routing; send a real test afterward.

For a zone apex, provisioning may enable Email Routing and its DNS records. Only use this when Cloudflare should handle mail for that apex. `provision_catchall DOMAIN=example.com` changes the **zone-wide** catch-all; a subdomain that resolves to a parent zone is rejected. See [subdomain onboarding](https://developers.cloudflare.com/email-service/configuration/subdomains/).

Replace the scaffolded mailbox's `process` with your application logic. For tenant or mailbox selection, use the authenticated SMTP recipient rather than the sender-controlled MIME `To`/`Cc` headers:

```ruby
class ApplicationMailbox < ActionMailbox::Base
  routing ->(inbound) { Cloudflare::Email::Envelope.for(inbound)&.fetch("to")&.match?(/\Asupport@/i) } => :support
end
```

`Cloudflare::Email::Envelope.for(inbound_email)` returns a string-keyed `{"from" => "sender@example.com", "to" => "support@example.com"}` hash, or `nil` for legacy ingress. The metadata is stored on the raw-email blob before routing jobs enqueue. It does not modify the MIME source. Envelope sender information records the SMTP reverse path; it does not authenticate the human sender. An empty `from` is valid for bounces.

Upgrade Rails before deploying the updated Worker. Legacy signatures remain accepted but never authenticate envelope headers, including similarly named MIME headers. The new Worker requires ASCII dot-atom addresses, at most 254 bytes with a 64-byte local part. Quoted local parts, address literals, and internationalized addresses are not supported by this envelope format.

Successful ingress storage returns HTTP 200; duplicate storage returns 200 too. The timestamp window limits request age, but is not a one-time replay ledger. Version 2 deduplication includes the exact SMTP recipient, so identical MIME delivered to separate To/Cc/Bcc recipients creates separate inbound records while a retry for the same recipient creates none.

The Worker has a 15-second Rails request timeout and rejects redirects. Non-2xx responses, timeouts, and network failures call `message.setReject`. There is no durable buffering of inbound email: an application outage can reject mail. Storage acceptance does not guarantee later mailbox-job success. Monitor Rails jobs and Cloudflare Worker logs.

### Local development and deployment

Start Rails, then:

```sh
bin/rails cloudflare:email:deploy_worker
bin/rails cloudflare:email:dev
```

The dev task requires `cloudflared`, refuses environments other than development, and updates the existing development Worker's URL to a temporary tunnel. It sends a localhost Host header to Rails so the normal development host check accepts the request. Configure a separate development receiving address and route. Stopping the tunnel leaves that URL in the development Worker until the next update. A Worker deployed without a URL rejects mail until the tunnel sets it.

For a custom installer `--worker-dir`, pass `SCRIPT=custom-directory/src/index.js` to the Ruby `deploy_worker` task. The installer prints the corresponding command.

Ruby deployment and Wrangler use matching names: `cloudflare-email-ingress-development`, `-staging`, and `-production`. The optional Wrangler path requires Node 22.12+ (or a supported newer version):

```sh
cd cloudflare-worker
npm ci
npx wrangler secret put INGRESS_SECRET --env production
npx wrangler secret put RAILS_INGRESS_URL --env production
npm run deploy -- --env production
```

See the [Worker README](templates/worker/README.md). Existing deployments/templates are not automatically migrated; verify routing before switching names.

Rotate the shared ingress secret in Rails and the corresponding Worker during a coordinated deployment. This version has no overlapping-key rotation window; requests can fail while secrets differ.

## Outbound delivery events

The new `DeliveryEvent` and `EventConsumer` APIs consume Cloudflare Email Sending lifecycle events through an HTTP pull queue: delivered, deferred, bounced, failed, rejected, and complained.

```ruby
consumer = Cloudflare::Email::EventConsumer.new(
  account_id: ENV.fetch("CLOUDFLARE_ACCOUNT_ID"),
  api_token: ENV.fetch("CLOUDFLARE_QUEUES_TOKEN"),
  queue_id: ENV.fetch("CLOUDFLARE_EVENT_QUEUE_ID"),
  domains: ["mail.example.com"],
)
consumer.poll do |event|
  DeliveryEventProcessor.call(event) # Your durable, idempotent application handler
end
```

Each event is acknowledged only after the handler returns normally. Configure a dedicated queue, subscription, retry policy, and dead-letter queue first. See the complete [Rails and Ruby delivery-event setup](docs/delivery-events.md).

## Thread correlation and signed Message-IDs

Prefer storing the provider's returned `message_id` with your conversation and correlating inbound `In-Reply-To` / `References` against that record. Correlation does not authenticate the sender or authorize an action.

`SecureMessageId` remains available for transports that preserve custom Message-IDs. It signs a compact JSON payload with HMAC-SHA256 and enforces a default 30-day age limit. It proves payload integrity, not the identity of the person replying. Payloads are encoded, not encrypted, and anyone who sees a token can reuse it until it expires.

Cloudflare's current [header documentation](https://developers.cloudflare.com/email-service/reference/headers/) describes Message-ID as platform-controlled. **The September 10 live test confirmed that Cloudflare replaced custom signed IDs**, including raw-MIME and ActionMailer sends. Store the provider ID for Cloudflare reply correlation. See [thread correlation](docs/thread-correlation.md) and the [live evidence](docs/verification/2026-09-10-live.md).

## Retry and configuration

`Client.new` options are also accepted by `config.action_mailer.cloudflare_settings`:

| Option | Default |
|---|---|
| `account_id`, `api_token` | Required |
| `base_url` | `https://api.cloudflare.com/client/v4` |
| `timeout` | 30 seconds for open/read/write |
| `retries` | 3 additional attempts |
| `initial_backoff` | 0.5 seconds, doubling |
| `max_retry_after` | 60 seconds |
| `retry_ambiguous` | `false` |
| `logger` | `nil`, optional `warn` logger |

By default, only 429 responses and pre-send connection failures retry. Numeric and HTTP-date `Retry-After` values are honored up to the cap. Read/write timeouts, connection resets, and 5xx responses may occur after acceptance; they raise without automatically resending. Setting `retry_ambiguous: true` restores retries for those failures and can send duplicates.

No idempotency key is sent. Reusing Message-ID does not guarantee deduplication or exactly-once delivery. Account for ActiveJob's retry policy too: retrying the whole mailer job can resend even when this client's retries are disabled.

Errors inherit from `Cloudflare::Email::Error`: `ConfigurationError`, `AuthenticationError`, `ValidationError`, `RateLimitError`, `ServerError`, `NetworkError`, and `SecureMessageId::InvalidToken`. API errors expose `status` and parsed `response`.

## Observability and permissions

Notifications: `cloudflare_email.send` / `send_raw` include `account_id`, `path`, `status`, `message_id`, and all four recipient outcome arrays. `cloudflare_email.ingress` includes `bytes`, `result` (`ok`, `duplicate`, `bad_signature`, `stale`), and the stored `message_id` when available. `cloudflare_email.delivery_event` wraps handler execution with `event_id`, `message_id`, and lifecycle `status`; it does not report queue acknowledgement completion. Instrumentation errors include ActiveSupport's exception metadata.

| Task | Purpose / credentials |
|---|---|
| `doctor` | Read diagnostics with runtime token; limited read permissions are reported |
| `send_test FROM=... TO=...` | Send a real message using runtime send permission |
| `deploy_worker URL=https://...` | Management token: Workers Scripts Edit |
| `provision_route ADDRESS=...` | Management token: Zone Read, Email Routing Rules Edit; DNS Read for subdomain checks; routing-settings write permission for apex enablement |
| `provision_catchall DOMAIN=...` | Same routing management permissions; changes the zone-wide catch-all |
| `dev` | Management token: Workers Scripts Edit; development only |
| `consume_events` | Separate Queues Read/Write token, queue ID, configured handler |

Management tasks fall back to the runtime token if `management_token` is unset. Restrict scopes and accounts to the operations you need. Event consumers use a separate `queues_token` and do not fall back to a send token.

## SMTP alternative

Cloudflare also supports authenticated SMTP. Existing Rails SMTP applications can use it without this gem's delivery method:

```ruby
config.action_mailer.delivery_method = :smtp
config.action_mailer.smtp_settings = {
  address: "smtp.mx.cloudflare.net",
  port: 465,
  ssl: true,
  authentication: :plain,
  user_name: "api_token",
  password: ENV.fetch("CLOUDFLARE_SMTP_TOKEN"),
}
```

Cloudflare documents Email Sending Edit permission for SMTP, implicit TLS on port 465, and no outbound STARTTLS on 587. See [SMTP documentation](https://developers.cloudflare.com/email-service/api/send-emails/smtp/). Remove the generated `:cloudflare` initializer override if switching to SMTP.

## Development and verification

```sh
bundle install
bundle exec rake test
bundle exec ruby script/verify_package.rb
BUNDLE_GEMFILE=gemfiles/rails_7_2.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rails_7_2.gemfile bundle exec rake test
cd templates/worker
npm ci
npm test
npm run check
npm audit
```

Tests include actual Rails boot/installation, ActionMailbox persistence and mailbox processing, task orchestration, HTTP-mocked API behavior, and Worker unit tests. CI also builds and installs the packaged gem and runs a real local workerd-to-Rails check. Run the latter with:

```sh
BUNDLE_GEMFILE=gemfiles/local_ingress.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/local_ingress.gemfile bundle exec ruby script/verify_local_ingress.rb
```

Install the Worker tooling first; Node 22+ must be on PATH (or set `NODE_BINARY` to its executable). This uses synthetic mail and temporary loopback services, not a deployed Cloudflare account. The development bundle pins JSON below 3 because current tested Rails versions require its positional-options API.

See the [verification report](docs/verification/2026-09-10.md) for evidence, the historical dogfood inventory, Rebulk integration findings, and remaining live-provider checks.

A subsequent [live verification pass](docs/verification/2026-09-10-live.md) exercised isolated sending, deployed ingress, binary attachments, reply threading, real LLM processing, and delivery-event redelivery/acknowledgement under `test.rebulk.com`. All temporary cloud resources were removed afterward. No DNS changes or RubyGems publication occurred. The report records remaining limits, including inbound envelope-aware mailbox selection and LLM draft quality.

MIT license.
