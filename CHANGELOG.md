# Changelog

## Unreleased

- **Per-environment Worker naming**: the default Worker is now
  `cloudflare-email-ingress-#{Rails.env}` instead of a single shared
  `cloudflare-email-ingress`. Critical fix — `cloudflare:email:dev` can no
  longer clobber the production Worker's `RAILS_INGRESS_URL`. Prod and
  dev/staging deploy as separate scripts with separate secrets.
- **`bin/rails cloudflare:email:provision_route ADDRESS=addr@domain.com`** —
  one-command Email Routing setup via Cloudflare API. Looks up the zone
  owning the domain, enables Email Routing if needed, creates or updates a
  rule binding that address to the env-scoped Worker. Idempotent.
- **`bin/rails cloudflare:email:deploy_worker`** — pure-Ruby Worker deployer
  that talks to the Cloudflare Workers API directly. No wrangler, Node, or
  npm required. Uploads the Worker script and sets both secrets
  (`INGRESS_SECRET` from Rails credentials, `RAILS_INGRESS_URL` from the
  `URL=` env var) in one shot.
- **Worker template rewritten in plain JavaScript** (dropped TypeScript from
  the deploy path). Same logic, deployable as an ES module without a build
  step. The `vitest` test suite still covers it.
- **`cloudflare:email:dev` no longer needs wrangler** — uses the same Ruby
  Worker deployer to update the tunnel URL on the deployed Worker.
- **Install generator scaffolds a `MainMailbox`** (interactive prompt) with a
  `routing :all => :main` catch-all so inbound emails have somewhere to land
  on a fresh Rails app — avoids `ActionMailbox::Router::RoutingError` on the
  first test message.
- **Install generator runs `bin/rails action_mailbox:install`** automatically
  if ActionMailbox isn't set up in the app yet (interactive prompt).
- **`bin/rails cloudflare:email:doctor`** — diagnostic runner that verifies every
  configuration layer (credentials, token validity, account access, sending
  domains, ingress secret, ActionMailbox + delivery method wiring).
- **`bin/rails cloudflare:email:send_test TO=...`** — one-shot test send using
  current config; auto-infers the FROM address from verified sending domains.
- **`bin/rails cloudflare:email:dev`** — spins up a `cloudflared` tunnel, updates
  the Worker's `RAILS_INGRESS_URL` secret to point at it, tails Worker logs.
- **Generator** now detects `wrangler` and offers to deploy the Worker + set
  secrets in one pass (skip via `--deploy-worker=false`).
- **Generator** post-install message includes dashboard deep-links for API
  tokens, sending domains, and email routing pages.
- Emit `ActiveSupport::Notifications` events (`cloudflare_email.send`,
  `cloudflare_email.send_raw`, `cloudflare_email.ingress`).
- Honor `Retry-After` headers on 429 responses (capped at `max_retry_after`,
  default 60s).
- Generator `--all-envs` flag also configures `development.rb` and `test.rb`.
- Response handling updated to match the real API shape: `delivered`,
  `queued`, and `permanent_bounces` are arrays of email strings (not hashes);
  `message_id` returns `nil` since Cloudflare does not include one.
- Ships a vitest test harness for the bundled Cloudflare Worker.
- Verified against Rails 7.1, 7.2, 8.0, and 8.1 via `gemfiles/*.gemfile`.

## 0.1.0 — 2026-04-16

Initial release.

- `Cloudflare::Email::Client` — plain-Ruby HTTP client for the Email Sending API.
  Supports `send` (structured) and `send_raw` (RFC822). Retries on 429/5xx/network
  errors with exponential backoff.
- `Cloudflare::Email::DeliveryMethod` — ActionMailer delivery method registered
  on the `:cloudflare` symbol. Uses `send_raw` so full MIME round-trips.
- `Cloudflare::Email::IngressController` — ActionMailbox ingress mounted at
  `/rails/action_mailbox/cloudflare/inbound_emails`. Verifies HMAC-SHA256
  signatures in constant time, rejects stale timestamps (5-min replay window).
- Cloudflare Email Worker template (`templates/worker/`) that signs and forwards
  inbound mail to the Rails ingress.
- `cloudflare:email:install` generator that writes the initializer, copies the
  Worker template, generates a strong ingress secret, and prints the deploy
  commands.
