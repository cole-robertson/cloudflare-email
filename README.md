# cloudflare-email

A Ruby gem for [Cloudflare's Email Service](https://blog.cloudflare.com/email-for-agents/)
(public beta, April 2026). Send mail from Rails via an `ActionMailer` delivery
method; receive mail via an `ActionMailbox` ingress backed by a shipped
Cloudflare Email Worker. Works as a plain Ruby client too.

```ruby
# Gemfile
gem "cloudflare-email"
```

---

## Three-minute setup

```sh
bundle add cloudflare-email
bin/rails generate cloudflare:email:install    # interactive — scaffolds everything
bin/rails credentials:edit                     # fill in the 3 secrets
bin/rails cloudflare:email:doctor              # verify wiring
TO=you@example.com bin/rails cloudflare:email:send_test   # prove outbound
```

The installer asks three questions:

1. **Deploy the Worker now via wrangler?** — if yes, it runs `npm install`, sets
   both Worker secrets, and `wrangler deploy`s in one pass.
2. **Scaffold a default MainMailbox + catch-all route?** — if yes, inbound mail
   has somewhere to land immediately (no `RoutingError` on your first test).
3. **Install ActionMailbox if missing?** — runs `bin/rails action_mailbox:install`
   and migrates the DB for you if the app doesn't have it yet.

After install, `bin/rails credentials:edit`:

```yaml
cloudflare:
  account_id: <your-cloudflare-account-id>
  api_token:  <email-send-scoped-api-token>
  ingress_secret: <generated-by-the-installer>
```

---

## Dashboard setup (one-time, per domain)

Cloudflare splits "sending" and "receiving" into separate features. You'll
visit two places in the dashboard:

### 1. To send mail — Sending Domain

`dash.cloudflare.com` → your zone → **Email** → **Email Sending** →
**Sending Domains** → **Add Sending Domain**.

- Pick a subdomain (e.g. `mail.yourdomain.com`). Don't use the apex if you have
  real Google Workspace / Outlook on it.
- Cloudflare auto-publishes DKIM on the zone if it's on Cloudflare DNS.
- Add SPF + DMARC on the apex:
  ```
  TXT @       v=spf1 include:_spf.mx.cloudflare.net ~all
  TXT _dmarc  v=DMARC1; p=quarantine; rua=mailto:postmaster@yourdomain.com
  ```
- Wait until the dashboard shows "Verified" before sending (otherwise you'll
  get a vague `email.sending.error.internal_server` 500).

### 2. To receive mail — Email Routing

Same dashboard → **Email** → **Email Routing**.

- Enable Email Routing on the domain (adds MX records) — or use a dedicated
  subdomain (e.g. `in.yourdomain.com`) so you don't touch the apex MX if
  Google Workspace / Outlook is there. See [Apex vs subdomain](#apex-vs-subdomain-for-inbound).
- Add a **Route** for the address you want (`cole@in.yourdomain.com`) →
  **Send to a Worker** → `cloudflare-email-ingress` (the Worker the installer
  deployed).

### API token scopes

Create at `dash.cloudflare.com/profile/api-tokens`. Use **Custom Token** with:

- **Account** → **Email Sending** → **Send** (required)
- **Account** → **Workers Scripts** → **Edit** (required only if you want the
  installer or `bin/rails cloudflare:email:dev` to manage the Worker for you)

Account Resources: scope to the single account, not "All accounts".

---

## Apex vs subdomain for inbound

**Don't point your apex MX at Cloudflare** if you already have Google Workspace
or another provider on it. MX records are domain-level, so doing so routes
every colleague's email through Cloudflare first.

Instead, use a subdomain for agent/automation email:

- `in.yourdomain.com` or `agent.yourdomain.com`
- Enable Email Routing **on that subdomain only**
- Route `cole@in.yourdomain.com` → Worker
- Your apex MX stays on Google; colleagues unaffected

If you want your real `cole@yourdomain.com` mail to *also* reach the agent,
set up a Google Workspace routing rule that BCCs incoming mail to
`cole@in.yourdomain.com`. Then you read mail normally in Gmail AND the agent
gets a copy.

---

## What gets installed

- **`Cloudflare::Email::Client`** — pure-Ruby HTTP client. `send` and `send_raw`
  endpoints, retries on 429/5xx/network with exponential backoff, Retry-After
  header honored.
- **ActionMailer delivery method** registered on `:cloudflare`. Uses
  `send_raw` internally so MIME round-trips exactly (attachments, multipart,
  threading headers).
- **ActionMailbox ingress** mounted automatically at
  `/rails/action_mailbox/cloudflare/inbound_emails`. Verifies HMAC-SHA256
  signatures in constant time, 5-minute replay window.
- **Cloudflare Email Worker template** under `cloudflare-worker/`. Deployable
  via `wrangler` — reads raw MIME from `message.raw`, signs, POSTs to your
  Rails ingress. Non-2xx from Rails → `message.setReject` → sender bounce
  (no silent drops).
- **`MainMailbox` scaffold** — optional, generated interactively. A stub with
  `routing :all => :main` so inbound email has somewhere to land on day one.
- **`ActiveSupport::Notifications`** events: `cloudflare_email.send`,
  `cloudflare_email.send_raw`, `cloudflare_email.ingress`.

---

## Rake tasks

| Task | What it does |
|---|---|
| `cloudflare:email:doctor` | Checks credentials, API token validity, sending domain status, ingress secret strength, `ActionMailbox.ingress = :cloudflare`, delivery method registration. Exit code 1 on any failure. |
| `cloudflare:email:send_test` | One-shot test send. `TO=addr` required; `FROM=addr` optional (auto-detected from verified sending domains). |
| `cloudflare:email:dev` | Spins up a `cloudflared` tunnel to your running Rails server, auto-updates the deployed Worker's `RAILS_INGRESS_URL` secret, tails Worker logs. Ctrl-C to stop. |

### Typical doctor output

```
cloudflare-email doctor — v0.1.0

  [ok]    Rails app                          MyApp::Application (development)
  [ok]    credentials.cloudflare.account_id  0f65c87e...
  [ok]    credentials.cloudflare.api_token   cfut_zKC...
  [ok]    API token valid                    active
  [ok]    Account accessible                 send-scoped token (no account read — this is fine)
  [skip]  Sending domains                    send-scoped token can't list (check the dashboard)
  [ok]    Ingress secret                     set (64 chars)
  [ok]    ActionMailbox ingress              :cloudflare
  [ok]    Delivery method :cloudflare        registered

  Everything looks good.
```

---

## Plain Ruby usage (no Rails)

```ruby
require "cloudflare-email"

client = Cloudflare::Email::Client.new(
  account_id: ENV["CLOUDFLARE_ACCOUNT_ID"],
  api_token:  ENV["CLOUDFLARE_API_TOKEN"],
)

response = client.send(
  from:    { address: "agent@acme.com", name: "Acme Agent" },
  to:      "user@example.com",
  subject: "Hello",
  text:    "Plain body",
  html:    "<p>HTML body</p>",
  reply_to: "thread+abc@acme.com",
  headers:  { "In-Reply-To" => "<msg-123@acme.com>" },
  attachments: [{
    content:  Base64.strict_encode64(File.read("report.pdf")),
    filename: "report.pdf",
    type:     "application/pdf",
  }],
)

response.success?     # => true
response.delivered    # => ["user@example.com"]
response.message_id   # => nil (Cloudflare does not return a message ID)
```

For full MIME control, use `client.send_raw(from:, recipients:, mime_message:)`.

---

## Rails usage

Send mail like any ActionMailer:

```ruby
class WelcomeMailer < ApplicationMailer
  def welcome(user)
    mail(to: user.email, subject: "Welcome") do |format|
      format.text { render plain: "Hi #{user.name}" }
      format.html { render "welcome_html" }
    end
  end
end

WelcomeMailer.welcome(user).deliver_later
```

Receive mail by writing a mailbox (the installer's `MainMailbox` is a good
starting point):

```ruby
class SupportMailbox < ApplicationMailbox
  def process
    Ticket.create!(
      sender:  mail.from.first,
      subject: mail.subject,
      body:    mail.body.decoded,
      message_id: inbound_email.message_id,
    )
  end
end

# app/mailboxes/application_mailbox.rb
class ApplicationMailbox < ActionMailbox::Base
  routing /^support@/i => :support
  routing :all         => :main
end
```

---

## Configuration

| Setting | Default | Notes |
|---|---|---|
| `account_id` | — | Required. Cloudflare account ID. |
| `api_token` | — | Required. Token with `Email Sending: Send` permission. |
| `base_url` | `https://api.cloudflare.com/client/v4` | Override for testing. |
| `retries` | `3` | Retries on 429, 5xx, network errors. |
| `initial_backoff` | `0.5` | Seconds; doubles each retry. |
| `max_retry_after` | `60` | Upper bound on sleep when honoring `Retry-After`. |
| `timeout` | `30` | Seconds. Both open and read timeout. |
| `logger` | `nil` | Responds to `#warn`. Logs retries. |

In Rails: `config.action_mailer.cloudflare_settings = { ... }`.

---

## Retry, rate limit, idempotency

- Retries on 429, 5xx, and network errors with exponential backoff.
- `Retry-After` headers on 429 are honored, capped at `max_retry_after`.
- **Cloudflare does not accept an idempotency key** and **does not return
  a `message_id`** in the send response. A network error or 5xx during retry
  could in theory cause double-delivery. Dedupe on your side via the outbound
  `Message-ID` header that the `Mail` gem auto-generates.

---

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

Each carries `#status` and `#response` (the parsed Cloudflare error body).

---

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
  # payload[:result] => :ok | :bad_signature | :stale
  StatsD.increment("cf_email.ingress", tags: ["result:#{event.payload[:result]}"])
end
```

Events:

| Name | Payload keys |
|---|---|
| `cloudflare_email.send` | `:account_id`, `:path`, `:status`, `:message_id` (nil) |
| `cloudflare_email.send_raw` | `:account_id`, `:path`, `:status`, `:message_id` (nil) |
| `cloudflare_email.ingress` | `:bytes`, `:result`, `:message_id` (extracted from inbound MIME when `:ok`) |

---

## How inbound works

Cloudflare Email Routing delivers inbound mail to an [Email Worker](https://developers.cloudflare.com/email-routing/email-workers/),
not an HTTPS webhook — you can't just point it at a URL.

This gem's shipped Worker bridges that gap:

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

If Rails responds non-2xx the Worker calls `message.setReject`, so the sender
gets a bounce (no silent drops).

---

## Development loop

For inbound dev (Rails running locally, Cloudflare needs a public URL):

```sh
bin/rails server                              # in one terminal
bin/rails cloudflare:email:dev                # in another
```

`cloudflare:email:dev` starts a `cloudflared` tunnel, updates the Worker's
`RAILS_INGRESS_URL` to point at it, and tails Worker logs. Send mail to your
routed address; it flows through Cloudflare → Worker → tunnel → local Rails.

Requires `cloudflared` and `wrangler` installed and authenticated.

---

## Credential rotation

**Ingress secret** (HMAC shared secret):

1. `bin/rails credentials:edit` — update `cloudflare.ingress_secret`.
2. `cd cloudflare-worker && wrangler secret put INGRESS_SECRET` — paste the
   same value, then `wrangler deploy`.

Rotate both sides together; there's no overlap window. If Worker and Rails
disagree, inbound mail bounces with 401 and the sender gets a delivery failure.

**API token**: generate a new one, update `cloudflare.api_token` in
credentials, revoke the old one.

---

## Dev / test / production environments

By default the installer only sets `config.action_mailbox.ingress = :cloudflare`
in **production.rb**. In development and test, `ActionMailbox.ingress` defaults
to `nil` and the ingress endpoint returns 404.

To enable in all environments:

```sh
bin/rails generate cloudflare:email:install --all-envs
```

…or add to any `config/environments/*.rb`:

```ruby
config.action_mailbox.ingress = :cloudflare
config.hosts << /.*\.trycloudflare\.com\z/   # if you tunnel in dev
```

---

## Compatibility

- **Ruby**: 3.1+
- **Rails**: 7.1, 7.2, 8.0, 8.1
- **Cloudflare Email Service**: public beta (April 2026)

---

## Testing

Bring up the full stack locally:

```sh
cd trial
bundle install
bin/rails db:prepare RAILS_ENV=test
bin/rails test             # 20 integration tests exercise outbound + inbound
```

Run the Ruby test suite under each supported Rails version:

```sh
BUNDLE_GEMFILE=gemfiles/rails_7_1.gemfile bundle exec rake test
BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle exec rake test
```

Run the Worker TypeScript tests:

```sh
cd templates/worker
npm install --legacy-peer-deps
npm run typecheck
npm test
```

---

## Status

**v0.1**. Cloudflare Email Service is itself in public beta. Expect API shape
adjustments on their end. The gem's unit + trial tests are verified against
live Cloudflare for both outbound and inbound. Issues and PRs welcome.

Deferred for later:

- Subdomain / DNS / Email Routing provisioning via API
- Mail interceptors (dev sandbox, redirect)
- Reply-threading helpers matching the JS Agents SDK's `createSecureReplyEmailResolver`
- Server-side template support (if/when Cloudflare ships templates)

---

## License

MIT.
