# Cloudflare Email × Rails — Gem Plan

**Status:** ready to execute · v0.1 scope · 2026-04-16

A single Ruby gem, **`cloudflare-email`**, that wraps Cloudflare's public-beta Email Service (announced Agents Week, April 2026) so it feels native in Rails: `config.action_mailer.delivery_method = :cloudflare` for outbound, an ActionMailbox ingress + a shipped Cloudflare Worker template for inbound. The core HTTP client works fine without Rails — the Railtie loads conditionally.

## Why one gem (not two)

Considered splitting into `cloudflare-email` (pure Ruby) + `cloudflare-email-rails` (resend's pattern), rejected:

- Railtie is ~50 lines and lazy-loaded via `ActiveSupport.on_load(:action_mailer)` — non-Rails users effectively pay nothing.
- Single gem = one version, one CHANGELOG, no version-pinning dance between sibling gems.
- `mailgun-ruby` ships unified and works fine; closer precedent than resend for our actual situation.
- Splitting later is trivial; merging later is annoying. Optionality favors unified.

Non-Rails Ruby users can `require "cloudflare/email/client"` directly without touching the Rails surface.

## Repo layout

```
cloudflare-email/
├── Gemfile
├── Rakefile
├── README.md
├── CHANGELOG.md
├── cloudflare-email.gemspec
├── lib/
│   ├── cloudflare-email.rb              # Top-level entry; conditionally loads Railtie
│   └── cloudflare/
│       └── email/
│           ├── version.rb
│           ├── client.rb                # HTTP client, auth, retries
│           ├── send.rb                  # POST /email/sending/send
│           ├── send_raw.rb              # POST /email/sending/send_raw
│           ├── response.rb              # Wraps API response
│           ├── error.rb                 # Error hierarchy
│           ├── railtie.rb               # Loaded only if Rails is present
│           ├── engine.rb                # Mounts ingress route
│           ├── delivery_method.rb       # ActionMailer adapter
│           ├── ingress_controller.rb    # ActionMailbox ingress
│           └── generators/
│               └── install_generator.rb
├── templates/
│   └── worker/
│       ├── wrangler.toml.tt
│       ├── package.json.tt
│       └── src/index.ts.tt              # Email Worker → POSTs raw MIME + HMAC to Rails
├── test/
│   ├── client_test.rb
│   ├── send_test.rb
│   ├── delivery_method_test.rb
│   └── ingress_controller_test.rb
└── examples/
    ├── plain_ruby.rb
    └── rails_app/                       # Tiny Rails app for integration testing
```

## Conditional loading

```ruby
# lib/cloudflare-email.rb
require "cloudflare/email/version"
require "cloudflare/email/error"
require "cloudflare/email/response"
require "cloudflare/email/client"

require "cloudflare/email/railtie" if defined?(::Rails::Railtie)
```

The Railtie itself uses `ActiveSupport.on_load(:action_mailer)` and `on_load(:action_mailbox)` so even within Rails it doesn't fire until those frameworks load.

## Core client (works without Rails)

### Public surface

```ruby
client = Cloudflare::Email::Client.new(
  account_id: ENV["CLOUDFLARE_ACCOUNT_ID"],
  api_token:  ENV["CLOUDFLARE_API_TOKEN"],
)

client.send(
  from:    { address: "agent@acme.com", name: "Acme Agent" },
  to:      "user@example.com",
  subject: "Hello",
  text:    "...",
  html:    "<p>...</p>",
  reply_to: "thread+abc@acme.com",
  headers:  { "In-Reply-To" => "<msg-123@acme.com>" },
  attachments: [{ content: base64, filename: "report.pdf", type: "application/pdf" }],
)
# => Cloudflare::Email::Response with #message_id, #delivered, #queued, #bounces

client.send_raw(from:, recipients:, mime_message: mail.to_s)
```

### Implementation notes

- **HTTP**: `net/http` only (no `faraday` dep — keep it light). One `Client#request` method, JSON in/out.
- **Auth**: `Authorization: Bearer <token>`. `account_id` interpolated into path.
- **Retries**: exponential backoff on 5xx and 429. Configurable, default 3 retries.
- **Errors**: `Cloudflare::Email::Error` (base) → `AuthenticationError`, `ValidationError`, `RateLimitError`, `ServerError`. Map from Cloudflare's `errors[]` array.
- **No idempotency key in the API** — surface this in docs; users can dedupe via `Message-ID`.
- **Response**: small `Response` struct exposing `message_id`, `delivered`, `queued`, `permanent_bounces`, plus raw hash escape hatch.

### Out of scope for v0.1

- Subdomain provisioning (`POST /zones/{zone_id}/email/sending/subdomains`) — most users do this once in the dashboard.
- DNS record fetching.
- Email Routing rules management.

## Rails integration (loaded conditionally)

### Outbound: ActionMailer delivery method

```ruby
# lib/cloudflare/email/railtie.rb
module Cloudflare::Email
  class Railtie < ::Rails::Railtie
    ActiveSupport.on_load(:action_mailer) do
      add_delivery_method :cloudflare, Cloudflare::Email::DeliveryMethod
    end
  end
end
```

```ruby
# lib/cloudflare/email/delivery_method.rb
class Cloudflare::Email::DeliveryMethod
  attr_accessor :settings

  def initialize(settings); @settings = settings; end

  def deliver!(mail)
    client = Cloudflare::Email::Client.new(
      account_id: settings.fetch(:account_id),
      api_token:  settings.fetch(:api_token),
    )
    response = client.send_raw(
      from:         mail.from.first,
      recipients:   (mail.to || []) + (mail.cc || []) + (mail.bcc || []),
      mime_message: mail.to_s,
    )
    mail.message_id = response.message_id if response.message_id
    response
  end
end
```

User config:
```ruby
# config/environments/production.rb
config.action_mailer.delivery_method   = :cloudflare
config.action_mailer.cloudflare_settings = {
  account_id: Rails.application.credentials.cloudflare.account_id,
  api_token:  Rails.application.credentials.cloudflare.api_token,
}
```

The `_settings` accessor is auto-created by `add_delivery_method`. Nothing else to wire.

### Inbound: ActionMailbox ingress (auto-mounted)

The gem ships a Rails Engine that auto-mounts the ingress route — user does **not** edit their `config/routes.rb`.

```ruby
# lib/cloudflare/email/engine.rb
module Cloudflare::Email
  class Engine < ::Rails::Engine
    isolate_namespace Cloudflare::Email

    initializer "cloudflare-email.routes" do |app|
      app.routes.append do
        post "/rails/action_mailbox/cloudflare/inbound_emails",
             to: "cloudflare/email/ingress#create",
             as: :rails_cloudflare_inbound_emails
      end
    end
  end
end
```

```ruby
# lib/cloudflare/email/ingress_controller.rb
class Cloudflare::Email::IngressController < ActionMailbox::BaseController
  before_action :authenticate
  param_encoding :create, "raw_email", Encoding::ASCII_8BIT

  REPLAY_WINDOW = 5 * 60

  def create
    raw = request.body.read
    ActionMailbox::InboundEmail.create_and_extract_message_id!(raw)
    head :ok
  end

  private

  def authenticate
    secret    = Rails.application.credentials.dig(:cloudflare, :ingress_secret) ||
                ENV["CLOUDFLARE_INGRESS_SECRET"]
    timestamp = request.headers["X-CF-Email-Timestamp"].to_s
    signature = request.headers["X-CF-Email-Signature"].to_s

    head(:unauthorized)    and return if secret.blank? || timestamp.empty? || signature.empty?
    head(:request_timeout) and return if (Time.now.to_i - timestamp.to_i).abs > REPLAY_WINDOW

    body = request.body.read; request.body.rewind
    expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")
    head(:unauthorized) and return unless ActiveSupport::SecurityUtils.secure_compare(expected, signature)
  end
end
```

User config:
```ruby
config.action_mailbox.ingress = :cloudflare
```
…plus `bin/rails credentials:edit` to set `cloudflare.ingress_secret`.

### Worker template (the differentiator)

Cloudflare delivers inbound mail to an Email Worker, not an HTTPS webhook. The gem ships a ready-to-deploy Worker that forwards raw MIME + HMAC to the Rails ingress.

`templates/worker/src/index.ts.tt`:
```ts
export default {
  async email(message, env) {
    const raw = await new Response(message.raw).arrayBuffer();
    const ts  = Math.floor(Date.now() / 1000).toString();
    const enc = new TextEncoder();
    const key = await crypto.subtle.importKey(
      "raw", enc.encode(env.INGRESS_SECRET),
      { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
    );
    const body = new Uint8Array([...enc.encode(`${ts}.`), ...new Uint8Array(raw)]);
    const sig  = await crypto.subtle.sign("HMAC", key, body);
    const hex  = [...new Uint8Array(sig)].map(b => b.toString(16).padStart(2, "0")).join("");

    const res = await fetch(env.RAILS_INGRESS_URL, {
      method: "POST",
      headers: {
        "Content-Type":         "message/rfc822",
        "X-CF-Email-Timestamp": ts,
        "X-CF-Email-Signature": hex,
      },
      body: raw,
    });
    if (!res.ok) message.setReject(`upstream ${res.status}`);
  },
};
```

### Generator: `bin/rails g cloudflare:email:install`

Interactive. Asks:
1. Outbound only, or outbound + inbound? (default: both)
2. If inbound: copy Worker template into `./cloudflare-worker/`? (default: yes)
3. Path to credentials section (default: `cloudflare`).

Then:
- Writes `config/initializers/cloudflare_email.rb` with `config.action_mailer.delivery_method = :cloudflare` and the settings hash skeleton.
- Prints `bin/rails credentials:edit` block to paste in (don't auto-edit credentials).
- If inbound: copies Worker template, sets `config.action_mailbox.ingress = :cloudflare`, prints `wrangler deploy` instructions, prints the ingress URL the user should set as `RAILS_INGRESS_URL` in Worker secrets.
- Final message: a checklist (Cloudflare DNS, API token scopes needed, address provisioning).

## Resolved design decisions

| Decision | Choice | Rationale |
|---|---|---|
| Gem split | **Single gem** (`cloudflare-email`) | Mailgun-style; lazy Railtie means non-Rails users pay nothing |
| Webhook signing | **Stripe-style HMAC-SHA256** over `"{ts}.{body}"` with separate `X-CF-Email-Timestamp` + `X-CF-Email-Signature` headers, 5-min replay window | De-facto standard; constant-time compare; replay protection built in |
| Ingress route | **Auto-mounted via Engine** at `/rails/action_mailbox/cloudflare/inbound_emails` | Matches Rails' built-in ingresses; user only sets `config.action_mailbox.ingress = :cloudflare` |

## Testing strategy

- **Core client**: stub HTTP with `webmock`. Cover happy paths for `send` / `send_raw`, all error classes, retry logic.
- **Rails integration**: a minimal Rails app under `examples/rails_app/`. `ActionMailer::TestHelper` for delivery_method. Request specs for ingress controller (good HMAC, bad HMAC, stale timestamp, missing headers).
- **Worker template**: a small `vitest` run with `@cloudflare/vitest-pool-workers` that sends a fake email through and asserts the POST shape. (Optional v0.1 — README + manual deploy may be enough initially.)
- **CI**: GitHub Actions matrix on Ruby 3.2/3.3/3.4 × Rails 7.1/7.2/8.0.

## v0.1 release checklist

- [ ] `cloudflare-email` 0.1.0 — client, send, send_raw, errors, retries
- [ ] Railtie + delivery method (conditional load)
- [ ] Engine + auto-mounted ingress controller with HMAC verification
- [ ] `cloudflare:email:install` generator
- [ ] Worker template under `templates/worker/`
- [ ] One worked example: Rails app sends a confirmation email and receives a reply that lands in `ApplicationMailbox`
- [ ] Blog-post-quality README with the 3-minute getting-started flow
- [ ] CI green across the matrix
- [ ] Publish to rubygems

## Deferred (v0.2+)

- Subdomain & DNS provisioning API (`Cloudflare::Email::Subdomains`)
- Email Routing rule management
- Multi-account / multi-token support per-message
- Mail interceptors (sandbox-mode, dev-redirect)
- Templated send (if/when Cloudflare ships server-side templates)
- ActionMailer preview integration
- Reply-threading helper that mirrors the JS Agents SDK's `createSecureReplyEmailResolver`

---

**Execution order:** scaffold gemspec → core `Client` + `send` → tests for client → delivery method + Railtie → ingress controller + Engine → generator → Worker template → example app → README.
