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

## Two independent paths

- **Send only** → skip to [Sending mail](#sending-mail). No Node, no Workers.
- **Send + Receive** → [Receiving mail](#receiving-mail). Ships a pure-Ruby
  Worker deployer. **No wrangler. No npm. No dashboard clicking.**
- Want belt-and-suspenders reply authentication? → [Secure reply-to addresses](#secure-reply-to-addresses).

---

# Sending mail

## Setup (3 minutes)

```sh
bundle add cloudflare-email
bin/rails generate cloudflare:email:install --no-inbound
bin/rails cloudflare:email:doctor              # verify wiring
TO=you@example.com bin/rails cloudflare:email:send_test
```

## Credentials — two options

The gem reads config from **Rails credentials first, then env vars**. Pick
whichever fits your workflow:

**Option A: Rails credentials** (recommended — encrypted, per-env)

```sh
bin/rails credentials:edit --environment production
```

```yaml
cloudflare:
  account_id: <your-cloudflare-account-id>
  api_token:  <email-send-scoped-api-token>
```

**Option B: `.env` / environment variables**

```env
CLOUDFLARE_ACCOUNT_ID=your-account-id
CLOUDFLARE_API_TOKEN=your-send-scoped-token
```

Use `dotenv-rails`, `foreman`, your platform's secret store (Fly, Render,
Heroku, Kamal) — anything that puts them into `ENV`.

## Dashboard setup (one-time)

1. **API token**: `dash.cloudflare.com/profile/api-tokens` → **Create Token** →
   **Custom Token**. Permission: **Account → Email Sending → Send**. Scope to
   your specific account.
2. **Sending Domain**: your zone → **Email** → **Email Sending** → **Sending
   Domains** → **Add Sending Domain**. Use a subdomain (e.g.
   `mail.yourdomain.com`), not the apex if you already have Google Workspace
   there.
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

---

# Receiving mail

Cloudflare Email Routing delivers inbound mail to an **Email Worker**, not an
HTTPS webhook — you can't just point it at a URL. This gem ships a Worker
that signs each message with HMAC-SHA256 and POSTs it to a Rails `ActionMailbox`
ingress it sets up for you.

**No wrangler, npm, or Node required.** The Worker is plain JavaScript; the
gem ships a pure-Ruby deployer that talks directly to Cloudflare's Workers
API. `wrangler` is supported as an alternative if you prefer the Cloudflare
CLI.

## Setup

```sh
bundle add cloudflare-email
bin/rails generate cloudflare:email:install    # interactive; scaffolds everything
bin/rails credentials:edit                     # fill in the 4 secrets (below)
bin/rails cloudflare:email:doctor              # verify
bin/rails cloudflare:email:deploy_worker URL=https://yourapp.com/rails/action_mailbox/cloudflare/inbound_emails
bin/rails cloudflare:email:provision_route ADDRESS=cole@in.yourdomain.com
```

That's it. Zero dashboard clicks once your tokens are created.

The interactive installer:

1. Copies the Worker template into `cloudflare-worker/` + writes the
   `config/initializers/cloudflare_email.rb` initializer.
2. Scaffolds a default `MainMailbox` + catch-all route (prompt) so inbound
   mail has somewhere to land on day one.
3. Runs `bin/rails action_mailbox:install` (prompt) if ActionMailbox is
   missing in the app.

## Credentials

Same two options as sending (credentials OR `.env`). For inbound you need
three values plus an ingress secret:

```yaml
cloudflare:
  account_id:     <your-cloudflare-account-id>
  api_token:      <runtime token — Email Sending: Send>
  management_token: <optional; Workers + Email Routing + Zone Read>
  ingress_secret: <generated by the installer>
```

Or via env vars:

```env
CLOUDFLARE_ACCOUNT_ID=...
CLOUDFLARE_API_TOKEN=...
CLOUDFLARE_MANAGEMENT_TOKEN=...   # optional
CLOUDFLARE_INGRESS_SECRET=...
```

## Tokens — why two?

For best security, split your tokens into runtime and management:

- **Runtime** (`api_token`): `Email Sending → Send` only. Lives in the app
  process at runtime. If leaked, attacker can send spam — that's it.
- **Management** (`management_token`): `Workers Scripts: Edit`, `Zone: Read`,
  `Email Routing: Edit`. Used by `deploy_worker`, `provision_route`, and
  `dev` tasks. **Never loaded by the running Rails app** — set it in your
  deploy environment only, or as a local `.env` for your laptop.

If only `api_token` is set, management tasks fall back to it. Single-token
setups are fine for solo devs / small projects; split tokens are strongly
recommended for production.

## Dashboard setup — one step

Only one dashboard visit needed: create the token(s) at
`dash.cloudflare.com/profile/api-tokens`. Choose the scopes from the
[Tokens](#tokens--why-two) table.

Everything else — sending domain, Email Routing enablement, MX records, route
rules — can be done in the dashboard OR automated from Ruby via the gem's
rake tasks. See the [rake task reference](#rake-tasks) below.

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

That task starts a `cloudflared` tunnel, updates your deployed Worker's
`RAILS_INGRESS_URL` secret to point at it, and ties up the terminal until
Ctrl-C. Send mail to your routed address; it flows Cloudflare → Worker →
tunnel → local Rails → your mailbox.

Only `cloudflared` required — no wrangler, no Node.

## Per-environment Worker isolation

The gem names the Worker `cloudflare-email-ingress-#{Rails.env}` by default.
Dev, staging, and prod deploy as **separate scripts** with separate secrets.
`bin/rails cloudflare:email:dev` only ever touches `-development`, so spinning
up a dev tunnel can never break production's inbound.

Deploy per environment:

```sh
RAILS_ENV=production  bin/rails cloudflare:email:deploy_worker URL=https://app.example.com/rails/action_mailbox/cloudflare/inbound_emails
RAILS_ENV=staging     bin/rails cloudflare:email:deploy_worker URL=https://staging.example.com/rails/action_mailbox/cloudflare/inbound_emails
```

Route different addresses to different Workers:

```sh
RAILS_ENV=production bin/rails cloudflare:email:provision_route ADDRESS=cole@in.yourdomain.com
RAILS_ENV=staging    bin/rails cloudflare:email:provision_route ADDRESS=cole@staging.in.yourdomain.com
```

## ⚠️ Apex vs subdomain

**Don't enable Email Routing on the apex** of a domain where colleagues run
email on Google Workspace or Outlook — MX records are domain-level, so
that'd route everyone's mail through Cloudflare first. Use a subdomain
(`in.yourdomain.com`).

If you want your own `cole@yourdomain.com` to also reach the agent, set up a
Google Workspace routing rule that BCCs incoming mail to
`cole@in.yourdomain.com`. You read mail in Gmail normally AND the agent
gets a copy.

## Rotating the ingress secret

Rotate Worker and Rails together (no overlap window):

1. `bin/rails credentials:edit` — update `cloudflare.ingress_secret`.
2. Re-run `bin/rails cloudflare:email:deploy_worker URL=...` to push the new
   secret to the Worker + redeploy.

If they disagree, inbound mail bounces with 401 and the sender gets a
delivery failure (no silent drop).

## How inbound flows

```
Sender's MTA
     │  MX lookup resolves to Cloudflare
     ▼
Cloudflare Email Routing
     │  (rule matched, action = "Send to Worker")
     ▼
cloudflare-email-ingress-{env} Worker  (reads message.raw, HMAC-signs)
     │  POST with Content-Type: message/rfc822
     │  + X-CF-Email-Timestamp + X-CF-Email-Signature
     ▼
Your Rails app — IngressController
     │  (verifies HMAC, 5-min replay window)
     ▼
ActionMailbox::InboundEmail.create_and_extract_message_id!
     │
     ▼
ApplicationMailbox → YourMailbox#process
```

If Rails responds non-2xx, the Worker calls `message.setReject` so the sender
gets a bounce. No silent drops.

---

# Secure replies

Optional but **highly recommended** for agent email flows: cryptographically
bind replies to the original thread so the inbound side can prove a reply
is legitimate and hasn't been forged. Inspired by Cloudflare's
[`createSecureReplyEmailResolver`](https://developers.cloudflare.com/agents/api-reference/email/)
from the JS Agents SDK, but stateless — no Durable Object storage needed.

The gem ships **two complementary strategies**. Both use HMAC-SHA256 +
timestamp + max-age, same cryptographic guarantees.

| Strategy | What gets signed | Pros | Use when |
|---|---|---|---|
| **`SecureMessageId`** (preferred) | Outbound `Message-ID:` header; reply carries it in `In-Reply-To:` | No size limit, clean reply-to address, no catch-all route required | Normal agent email where recipients use a regular mail client that preserves threading |
| `SecureReply` | Reply-to address local part | Works even if threading headers get stripped | Auto-forwarded mail, bounces, systems that rewrite `In-Reply-To:` |

Pick `SecureMessageId` unless you have a specific reason not to.

## `SecureMessageId` (preferred)

Sign the outbound `Message-ID:` with HMAC. When a user replies, their mail
client puts the original ID into the `In-Reply-To:` header — your mailbox
reads + verifies it there. No catch-all needed, no size constraint, clean
user-visible reply-to address.

### Outbound

```ruby
class AgentMailer < ApplicationMailer
  def ping(thread)
    signed_id = Cloudflare::Email::SecureMessageId.encode(
      payload: {
        thread_id: thread.id,
        user_id:   thread.user_id,
        kind:      "ping",
      },
      domain: "mail.yourdomain.com",
      secret: Rails.application.credentials.dig(:cloudflare, :reply_secret),
    )

    mail(
      to:         thread.user.email,
      from:       "agent@mail.yourdomain.com",
      reply_to:   "agent@in.yourdomain.com",   # clean, routable address
      subject:    "Re: #{thread.title}",
      message_id: signed_id,                    # sign the Message-ID
    ) { |f| f.text { render plain: "..." } }
  end
end
```

### Inbound

```ruby
class AgentMailbox < ApplicationMailbox
  def process
    ref = mail.in_reply_to || Array(mail.references).first
    if ref && Cloudflare::Email::SecureMessageId.match?(ref)
      payload = Cloudflare::Email::SecureMessageId.decode(
        ref,
        secret: Rails.application.credentials.dig(:cloudflare, :reply_secret),
      )
      Thread.find(payload["thread_id"]).ingest(mail)
    end
  rescue Cloudflare::Email::SecureMessageId::InvalidToken => e
    Rails.logger.warn("Invalid signed reply: #{e.message}")
  end
end
```

Route replies to `agent@in.yourdomain.com` normally (`provision_route`).
No catch-all needed — the signed state rides in the Message-ID, not the
recipient address.

## `SecureReply` (fallback, address-based)

Encode state into the reply-to address itself. Use this when you can't rely
on `In-Reply-To:` (auto-forwarders, bots, clients that strip threading).

## Why

Without signing, anyone who can guess your reply address pattern can deliver
arbitrary "replies" into your agent. With signing:

- Replies carry a cryptographically signed payload (thread ID, user ID, etc.)
- Signatures can't be forged without the secret
- Time-boxed with configurable max-age (30 days default)
- Tampered addresses are rejected with `InvalidToken`

## Outbound

```ruby
reply_to = Cloudflare::Email::SecureReply.encode(
  payload: { t: thread.id.to_s },             # keep it tiny (<20 bytes)
  domain:  "in.yourdomain.com",
  secret:  Rails.application.credentials.dig(:cloudflare, :reply_secret),
)
# => "reply.AIzyonsid...d72af1ef0ee87c2d6fc6be214c65ce69@in.yourdomain.com"

class AgentMailer < ApplicationMailer
  def ping(thread)
    mail(
      to:       thread.user.email,
      from:     "agent@mail.yourdomain.com",
      reply_to: reply_to,
      subject:  "Re: #{thread.title}",
    ) { |f| f.text { render plain: "How's it going?" } }
  end
end
```

## Inbound

```ruby
class MainMailbox < ApplicationMailbox
  def process
    recipient = mail.to.first

    if Cloudflare::Email::SecureReply.match?(recipient)
      payload = Cloudflare::Email::SecureReply.decode(
        recipient,
        secret: Rails.application.credentials.dig(:cloudflare, :reply_secret),
      )
      Thread.find(payload["t"]).ingest(mail)
    else
      # Handle other inbound
    end
  rescue Cloudflare::Email::SecureReply::InvalidToken => e
    Rails.logger.warn("Invalid secure reply: #{e.message} from=#{mail.from&.first}")
  end
end
```

The `match?` heuristic cheaply tests whether an address looks like a
SecureReply address (so you only attempt decode on candidates).

## Payload size

Local parts must fit within **RFC 5321's 64-char limit** (Cloudflare enforces
this). The encoding overhead is ~47 chars (local-part prefix + 4-byte binary
timestamp + 32-char HMAC), leaving roughly **12 bytes for your JSON payload**.

Stick to very short keys and short values:

```ruby
# Good: ~6 bytes JSON → address fits
payload: { t: "42" }

# Good: uuid/short hash as string → fits
payload: { t: "abc123" }

# Too big — raises PayloadTooLarge
payload: { thread_id: "some-long-uuid", user_id: 12345, action: "reply" }
```

For larger state, **store server-side and encode only a lookup id**:

```ruby
token = Thread.create_reply_token!(thread_id: 42, user_id: 7)   # stores in DB, returns short id
Cloudflare::Email::SecureReply.encode(payload: { t: token }, ...)
```

## To use this

You'll need a catch-all route on your inbound subdomain (since each reply
address is unique). One command:

```sh
DOMAIN=in.yourdomain.com bin/rails cloudflare:email:provision_catchall
```

And a `reply_secret` in credentials (or `CLOUDFLARE_REPLY_SECRET` env var):

```yaml
cloudflare:
  reply_secret: <openssl rand -hex 32>
```

## Compared to Cloudflare's JS SDK

| | Our SecureMessageId | Our SecureReply | CF `createSecureReplyEmailResolver` |
|---|---|---|---|
| Signing | HMAC-SHA256 (full 64-char) | HMAC-SHA256 (128-bit truncated) | HMAC-SHA256 (full) |
| Carrier | `Message-ID:` → `In-Reply-To:` | Reply-to address | Headers + Durable Object lookup |
| Statefulness | Stateless | Stateless | Stateful (DO storage) |
| Payload size | Large (~900 chars) | Tiny (~12 bytes) | No limit (in DO) |
| Catch-all needed | No | Yes | N/A |
| Works in plain Rails | Yes | Yes | Requires Workers + DO |

Same security properties (HMAC-SHA256, time-boxed with max-age), different
mechanism. `SecureMessageId` is the idiomatic Rails choice — stateless,
size-unconstrained, and matches email threading natively.

---

# Rake tasks

| Task | What it does |
|---|---|
| `cloudflare:email:doctor` | Checks credentials, API token validity, ingress secret strength, token split, `ActionMailbox.ingress = :cloudflare`, delivery method registration. Exit code 1 on failure. |
| `cloudflare:email:send_test` | One-shot test send. `TO=addr` required; `FROM=addr` auto-detected from verified sending domains. |
| `cloudflare:email:deploy_worker` | Deploys the Worker + sets both secrets via the Cloudflare API (pure Ruby). `URL=https://...` sets `RAILS_INGRESS_URL`. Targets `cloudflare-email-ingress-#{Rails.env}`. |
| `cloudflare:email:provision_route` | `ADDRESS=cole@domain.com`: creates (or updates) a Cloudflare Email Routing rule binding that address to the env-scoped Worker. Idempotent. |
| `cloudflare:email:provision_catchall` | `DOMAIN=in.example.com`: points the zone's catch-all rule at the env-scoped Worker. Essential for SecureReply. |
| `cloudflare:email:dev` | `cloudflared` tunnel + auto-update of the `-development` Worker's `RAILS_INGRESS_URL`. Inbound dev loop. |

## API token scopes

Create at `dash.cloudflare.com/profile/api-tokens` → **Custom Token**:

| Scope | Used by |
|---|---|
| Account → Email Sending → Send | Outbound (runtime token) |
| Account → Workers Scripts → Edit | `deploy_worker`, `dev` |
| Zone → Zone → Read | `provision_route`, `provision_catchall` |
| Zone → Email Routing → Edit | `provision_route`, `provision_catchall` |

**Scope to a single account** (not "All accounts"). Zone Resources should
cover the domains you'll route to.

---

# Reference

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
  `message_id` in send responses. Dedupe on your side via the outbound
  `Message-ID` header if you care about exactly-once semantics.

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
| `SecureReply::InvalidToken` | Signature mismatch, expired, malformed |
| `SecureReply::PayloadTooLarge` | Payload exceeds 64-char local-part limit |

Each carries `#status` and `#response` (parsed error body).

## Observability

Subscribe to `ActiveSupport::Notifications`:

```ruby
ActiveSupport::Notifications.subscribe("cloudflare_email.send_raw") do |event|
  Rails.logger.info("cf_email status=#{event.payload[:status]} duration=#{event.duration.round(1)}ms")
end

ActiveSupport::Notifications.subscribe("cloudflare_email.ingress") do |event|
  StatsD.increment("cf_email.ingress", tags: ["result:#{event.payload[:result]}"])
end
```

| Event | Payload keys |
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

# Worker JavaScript tests
cd templates/worker && npm install --legacy-peer-deps && npm test
```

A full end-to-end trial Rails app lives under `trial/` (not shipped in the gem).

---

## Status

**v0.1**. Cloudflare Email Service is itself in public beta. The gem is
verified end-to-end against live Cloudflare for outbound, inbound (HMAC
Worker pipe), Worker deploy (pure-Ruby API), Email Routing provisioning,
catch-all routing, and SecureReply encoding/decoding. 130 gem unit tests,
20 trial integration tests, 6 Worker vitest tests — all green.

Issues and PRs welcome.

## License

MIT.
