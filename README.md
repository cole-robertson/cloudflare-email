# cloudflare-email

A Ruby gem for [Cloudflare's Email Service](https://blog.cloudflare.com/email-for-agents/)
(public beta, April 2026). Two independent use cases:

- **Send** transactional email from Rails via an `ActionMailer` delivery method
  (or from plain Ruby via the client directly).
- **Receive** inbound email via an `ActionMailbox` ingress backed by a shipped
  Cloudflare Email Worker.

You can use just sending, just receiving, or both. Jump to the path you need:

- [Sending mail only →](#sending-mail)
- [Receiving mail (and sending) →](#receiving-mail)

```ruby
# Gemfile
gem "cloudflare-email"
```

---

# Sending mail

For teams that want to send transactional mail from Rails through Cloudflare
and are not dealing with inbound.

## Setup (3 minutes)

```sh
bundle add cloudflare-email
bin/rails generate cloudflare:email:install --no-inbound
bin/rails credentials:edit
bin/rails cloudflare:email:doctor
TO=you@example.com bin/rails cloudflare:email:send_test
```

`--no-inbound` skips the Worker template, ActionMailbox ingress config, and
mailbox scaffold — just the outbound pieces get installed.

Add to credentials:

```yaml
cloudflare:
  account_id: <your-cloudflare-account-id>
  api_token:  <email-send-scoped-api-token>
```

## Dashboard setup (one-time)

1. **API token**: `dash.cloudflare.com/profile/api-tokens` → **Create Token** →
   **Custom Token**. Permission: **Account → Email Sending → Send**. Scope to
   your specific account.
2. **Sending Domain**: your zone → **Email** → **Email Sending** → **Sending
   Domains** → **Add Sending Domain**. Use a subdomain (e.g. `mail.yourdomain.com`),
   not the apex if you have Google Workspace / Outlook there.
3. **SPF + DMARC** on the apex (DKIM is auto-published by Cloudflare):
   ```
   TXT @       v=spf1 include:_spf.mx.cloudflare.net ~all
   TXT _dmarc  v=DMARC1; p=quarantine; rua=mailto:postmaster@yourdomain.com
   ```
4. Wait until the dashboard shows "Verified" before sending (otherwise a vague
   `email.sending.error.internal_server` 500 comes back).

## Send mail

Standard ActionMailer — the `:cloudflare` delivery method is registered
automatically:

```ruby
class WelcomeMailer < ApplicationMailer
  def welcome(user)
    mail(to: user.email, from: "hello@mail.yourdomain.com", subject: "Welcome") do |format|
      format.text { render plain: "Hi #{user.name}" }
      format.html { render "welcome_html" }
    end
  end
end

WelcomeMailer.welcome(user).deliver_later
```

Attachments, multipart, threading headers, cc/bcc all round-trip through the
underlying `send_raw` API.

## Plain Ruby (no Rails)

```ruby
require "cloudflare-email"

client = Cloudflare::Email::Client.new(
  account_id: ENV["CLOUDFLARE_ACCOUNT_ID"],
  api_token:  ENV["CLOUDFLARE_API_TOKEN"],
)

response = client.send(
  from:    { address: "agent@mail.acme.com", name: "Acme Agent" },
  to:      "user@example.com",
  subject: "Hello",
  text:    "Plain body",
  html:    "<p>HTML body</p>",
  reply_to: "thread+abc@mail.acme.com",
  headers:  { "In-Reply-To" => "<msg-123@acme.com>" },
  attachments: [{
    content:  Base64.strict_encode64(File.read("report.pdf")),
    filename: "report.pdf",
    type:     "application/pdf",
  }],
)

response.success?   # => true
response.delivered  # => ["user@example.com"]
response.message_id # => nil (Cloudflare does not return a message ID)
```

For full MIME control: `client.send_raw(from:, recipients:, mime_message:)`.

That's it for sending. If you don't need inbound, skip to
[Observability](#observability), [Errors](#errors), or [Configuration](#configuration).

---

# Receiving mail

Inbound is more involved than outbound because Cloudflare Email Routing
delivers mail to an **Email Worker**, not an HTTPS webhook. This gem ships a
Worker that signs each message with HMAC-SHA256 and POSTs it to a Rails
`ActionMailbox` ingress it also sets up for you.

The Worker is plain JavaScript, and the gem ships a pure-Ruby deployer that
talks to Cloudflare's Workers API directly — **you don't need Node, npm, or
wrangler** to set this up. `wrangler` is supported as an alternative if you
prefer the Cloudflare-native tooling.

## Setup

Same install command, keep the default `--inbound`:

```sh
bundle add cloudflare-email
bin/rails generate cloudflare:email:install    # interactive
bin/rails credentials:edit
bin/rails cloudflare:email:doctor
```

The interactive installer:

1. Copies the Worker template into `cloudflare-worker/` and writes the
   `config/initializers/cloudflare_email.rb` initializer.
2. **Scaffolds a default `MainMailbox` + catch-all route** (prompt) so inbound
   mail has somewhere to land on day one (no `RoutingError` on your first
   test).
3. **Runs `bin/rails action_mailbox:install`** (prompt) if ActionMailbox is
   missing in the app.

After the installer and `credentials:edit`, **deploy the Worker**:

```sh
bin/rails cloudflare:email:deploy_worker URL=https://yourapp.com/rails/action_mailbox/cloudflare/inbound_emails
```

That's a pure-Ruby call to the Cloudflare API — no Node / npm / wrangler. It:

- Uploads `cloudflare-worker/src/index.js` as a module Worker named
  `cloudflare-email-ingress`
- Sets the Worker's `INGRESS_SECRET` from your Rails credentials
- Sets the Worker's `RAILS_INGRESS_URL` to the value you passed

**API token scope needed**: add `Account → Workers Scripts → Edit` to the
token (in addition to the `Email Sending → Send` scope used for outbound).

If you prefer wrangler:

```sh
cd cloudflare-worker
npm install --legacy-peer-deps
wrangler secret put INGRESS_SECRET        # paste the value from credentials
wrangler secret put RAILS_INGRESS_URL     # https://yourapp.com/rails/action_mailbox/cloudflare/inbound_emails
wrangler deploy
```

Credentials:

```yaml
cloudflare:
  account_id: <your-cloudflare-account-id>
  api_token:  <email-send-scoped-api-token>
  ingress_secret: <generated-by-the-installer>
```

The `ingress_secret` is the HMAC shared secret between the Worker and Rails.
Keep it long (≥32 chars, generated for you).

## Provision the Email Routing rule

Once the Worker is deployed, bind your address to it. One command does it:

```sh
ADDRESS=cole@in.yourdomain.com bin/rails cloudflare:email:provision_route
```

This looks up the Cloudflare zone that owns the domain, enables Email
Routing on it if needed, and creates (or updates) a rule sending mail for
that address to the env-scoped Worker (`cloudflare-email-ingress-#{Rails.env}`).
Idempotent — running it twice is safe.

**API token scope needed** for this task: add `Zone → Zone → Read` and
`Zone → Email Routing → Edit` to your token (in addition to `Email Sending:
Send` and `Workers Scripts: Edit`).

If you'd rather click through the dashboard: `dash.cloudflare.com` → your
zone → **Email** → **Email Routing** → **Routes** → add a route:
`cole@in.yourdomain.com` → **Send to a Worker** → select
`cloudflare-email-ingress-production` (or whichever env).

### ⚠️ Apex vs subdomain

**Don't enable Email Routing on the apex** of a domain where colleagues run
their email on Google Workspace or Outlook — MX records are domain-level, so
that would route every colleague's mail through Cloudflare first. Use a
subdomain for agent/automation email instead.

If you want your *own* real email (`cole@yourdomain.com`) to also reach the
agent, set up a Google Workspace routing rule that BCCs incoming mail to
`cole@in.yourdomain.com`. You read mail in Gmail normally AND the agent gets
a copy.

## Write your mailbox

The installer creates `MainMailbox` with a stub. Replace `#process`:

```ruby
# app/mailboxes/main_mailbox.rb
class MainMailbox < ApplicationMailbox
  def process
    YourAgentJob.perform_later(
      from: mail.from.first,
      subject: mail.subject,
      body: mail.body.decoded,
    )
  end
end
```

Route by address or content in `ApplicationMailbox`:

```ruby
class ApplicationMailbox < ActionMailbox::Base
  routing /^support@/i => :support
  routing :all         => :main
end
```

## Local development

You need a public HTTPS URL for Cloudflare to POST to. In dev that means
tunneling. Run `bin/rails server` in one terminal, then:

```sh
bin/rails cloudflare:email:dev
```

That task:

- Starts a `cloudflared` tunnel to your running Rails server
- Updates the deployed Worker's `RAILS_INGRESS_URL` secret to point at it
- Tails Worker logs

Send mail to your routed address; it flows Cloudflare → Worker → tunnel →
local Rails → your mailbox. Ctrl-C to stop.

Requires `cloudflared` and `wrangler` installed + authenticated.

## Rotating the ingress secret

Rotate Worker and Rails together (no overlap window):

1. `bin/rails credentials:edit` — update `cloudflare.ingress_secret`.
2. `cd cloudflare-worker && wrangler secret put INGRESS_SECRET` (paste the
   same new value) → `wrangler deploy`.

If they disagree, inbound mail bounces with 401 and the sender gets a
delivery failure (no silent drop).

## How the inbound pipe actually works

```
Sender's MTA
     │
     ▼  MX lookup resolves to Cloudflare
Cloudflare Email Routing
     │  (route matched, action = "Send to Worker")
     ▼
cloudflare-email-ingress Worker  (reads message.raw, signs HMAC)
     │
     ▼  POST with Content-Type: message/rfc822
Your Rails app — IngressController
     │  (verifies HMAC, 5-min replay window)
     ▼
ActionMailbox::InboundEmail.create_and_extract_message_id!
     │
     ▼
ApplicationMailbox → your Mailbox#process
```

Headers the Worker sends:

```
X-CF-Email-Timestamp: <unix seconds>
X-CF-Email-Signature: <HMAC-SHA256 hex of "{timestamp}.{raw_body}">
```

If Rails responds non-2xx, the Worker calls `message.setReject` so the sender
gets a bounce.

## Dev / test / production environments

By default the installer only sets `config.action_mailbox.ingress = :cloudflare`
in **production.rb**. In development and test, `ActionMailbox.ingress` defaults
to `nil` and the ingress endpoint returns 404.

Enable it everywhere with:

```sh
bin/rails generate cloudflare:email:install --all-envs
```

Or manually add to any `config/environments/*.rb`:

```ruby
config.action_mailbox.ingress = :cloudflare
config.hosts << /.*\.trycloudflare\.com\z/   # if tunneling in dev
```

---

# Reference

Applies to both sending and receiving.

## Rake tasks

| Task | What it does |
|---|---|
| `cloudflare:email:doctor` | Checks credentials, API token validity, ingress secret strength, `ActionMailbox.ingress = :cloudflare`, delivery method registration. Exit code 1 on failure. |
| `cloudflare:email:send_test` | One-shot test send. `TO=addr` required; `FROM=addr` auto-detected from verified sending domains if omitted. |
| `cloudflare:email:deploy_worker` | Deploys the Worker + sets both secrets via the Cloudflare API (pure Ruby, no wrangler/Node). `URL=https://...` sets `RAILS_INGRESS_URL`. Targets the Worker named `cloudflare-email-ingress-#{Rails.env}`. |
| `cloudflare:email:provision_route` | `ADDRESS=cole@domain.com`: creates (or updates) a Cloudflare Email Routing rule binding that address to the env-scoped Worker. Looks up the zone automatically. Idempotent. |
| `cloudflare:email:dev` | `cloudflared` tunnel + Worker `RAILS_INGRESS_URL` update via Cloudflare API. Only touches the `-development` Worker. Inbound dev loop. |

## API token scopes

Create at `dash.cloudflare.com/profile/api-tokens` as a **Custom Token**:

- **Account → Email Sending → Send** (required for outbound)
- **Account → Workers Scripts → Edit** (required to use
  `cloudflare:email:deploy_worker` or `cloudflare:email:dev` — i.e. to
  manage the Worker from Rails instead of the dashboard or wrangler)
- **Zone → Zone → Read** (required for `cloudflare:email:provision_route` —
  looks up the zone that owns your domain)
- **Zone → Email Routing → Edit** (required for `cloudflare:email:provision_route` —
  enables Email Routing and creates rules)

Account Resources: scope to a single account.

## Configuration

| Setting | Default | Notes |
|---|---|---|
| `account_id` | — | Required. |
| `api_token` | — | Required. `Email Sending: Send` permission. |
| `base_url` | `https://api.cloudflare.com/client/v4` | Override for testing. |
| `retries` | `3` | On 429 / 5xx / network errors. |
| `initial_backoff` | `0.5` | Seconds. Doubles each retry. |
| `max_retry_after` | `60` | Upper bound on `Retry-After` sleep. |
| `timeout` | `30` | Seconds. Open + read. |
| `logger` | `nil` | Responds to `#warn`. Logs retries. |

In Rails: `config.action_mailer.cloudflare_settings = { ... }`.

## Retry, rate limit, idempotency

- Retries on 429, 5xx, and network errors with exponential backoff.
- `Retry-After` on 429 is honored, capped at `max_retry_after`.
- **Cloudflare does not accept an idempotency key** and does not return a
  `message_id`. On a retried 5xx, double-delivery is theoretically possible.
  Dedupe on your side via the outbound `Message-ID` header if you care.

## Errors

All descend from `Cloudflare::Email::Error`:

| Class | Trigger |
|---|---|
| `ConfigurationError` | Bad init arguments |
| `AuthenticationError` | 401 / 403 |
| `ValidationError` | 400 / 422 or bad input |
| `RateLimitError` | 429 (retried first) |
| `ServerError` | 5xx (retried first) |
| `NetworkError` | Connection failure (retried first) |

Each carries `#status` and `#response` (parsed error body).

## Observability

Subscribe to `ActiveSupport::Notifications`:

```ruby
ActiveSupport::Notifications.subscribe("cloudflare_email.send_raw") do |event|
  Rails.logger.info(
    "cf_email delivered status=#{event.payload[:status]} " \
    "duration_ms=#{event.duration.round(1)}"
  )
end

ActiveSupport::Notifications.subscribe("cloudflare_email.ingress") do |event|
  StatsD.increment("cf_email.ingress", tags: ["result:#{event.payload[:result]}"])
end
```

Events:

| Name | Payload keys |
|---|---|
| `cloudflare_email.send` | `:account_id`, `:path`, `:status`, `:message_id` (nil) |
| `cloudflare_email.send_raw` | `:account_id`, `:path`, `:status`, `:message_id` (nil) |
| `cloudflare_email.ingress` | `:bytes`, `:result` (`:ok` / `:bad_signature` / `:stale`), `:message_id` when `:ok` |

## Compatibility

- **Ruby**: 3.1+
- **Rails**: 7.1, 7.2, 8.0, 8.1
- **Cloudflare Email Service**: public beta (April 2026)

## Testing the gem itself

```sh
# Gem unit tests
bundle exec rake test

# Under each supported Rails
BUNDLE_GEMFILE=gemfiles/rails_7_1.gemfile bundle exec rake test
BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle exec rake test

# Worker TypeScript tests
cd templates/worker && npm install --legacy-peer-deps && npm run typecheck && npm test
```

A full end-to-end trial Rails app lives under `trial/` (not shipped in the gem).

---

## Status

**v0.1**. Cloudflare Email Service is itself in public beta. The gem's unit and
trial tests are verified against live Cloudflare for both outbound and inbound.
Issues and PRs welcome.

Deferred for later:

- Subdomain / DNS / Email Routing provisioning via API
- Mail interceptors (dev sandbox, redirect)
- Reply-threading helpers matching the JS Agents SDK's `createSecureReplyEmailResolver`
- Server-side template support (if/when Cloudflare ships templates)

## License

MIT.
