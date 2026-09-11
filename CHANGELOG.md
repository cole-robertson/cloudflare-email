# Changelog

## 0.2.0 — Unreleased

- Authenticate SMTP envelope sender/recipient with the Worker's v2 HMAC format,
  persist trusted metadata before routing, and expose `Envelope.for(inbound_email)`.
  Preserve raw MIME and scope duplicate detection to the exact SMTP recipient.
  Require v2 ingress; remove v1 compatibility and the unused signed Message-ID
  helper. Coordinate Rails and Worker deployment; see docs/upgrading-0.2.md.

- Extract shared provider acceptance, delivery-event ordering, and Message-ID
  normalization primitives from the inbox application.
- Add an opt-in ActiveRecord event inbox and `cloudflare:email:tracking` generator:
  committed receipts before ACK, account/event uniqueness, payload-conflict
  detection, unmatched replay, and transactional handlers with explicit outcomes.

- Verify actual local workerd-to-Rails delivery in CI. This exposed and fixed an
  unsupported fetch redirect mode; use `manual` and reject the 3xx response.
  Add reusable package/fresh-install/task verification and a dated evidence report.

- Add outbound delivery events through Cloudflare Queues HTTP pull, typed event
  data, account/domain checks, per-message acknowledgement after handler success,
  and a Rails `consume_events` task. Optional Rails receipts provide durable
  deduplication; applications supply correlation and processing policy.
- Expose suppressed recipients and provider message IDs in responses/notifications;
  support cc/bcc-only structured sends and HTTP-date Retry-After headers.
- Default to retrying only rate limits and pre-send connection failures. Ambiguous
  network/5xx retries now require `retry_ambiguous: true` to accept duplication risk.
- Fix generated ENV credentials, send-only eager boot, duplicate ingress responses,
  accidental generator deployment tasks, and development environment isolation.
- Require subdomain routing DNS preflight; refuse misleading subdomain catch-all
  scope; use current apex DNS API and paginated rule lookup; surface setup failures.
- Update locked Worker tooling, require explicit Wrangler environments, bound
  forwarding requests to 15 seconds, and reject redirects. Add scheduled CI,
  dependency checks, actual Rails integration tests, and Ruby 4 / Rails 8.1 coverage.
- Require FROM for test sends; remove undocumented sending-domain discovery and
  misleading diagnostic claims. Update DNS, SMTP, retry, and signed-ID guidance.
- Bound legacy signed Message-ID output to 900 bytes; reject empty decode secrets.
  Live Cloudflare testing confirmed custom IDs are replaced; use provider IDs
  for correlation, not sender authentication. See docs/upgrading-0.2.md.
- Accept plain JSON queue bodies returned by live Email Sending subscriptions,
  retaining Base64 compatibility. Verify real delivery-event redelivery and ack.

## 0.1.0 — 2026-04-18

The notes below describe the original April implementation and its historical
verification. Current compatibility and security guidance is in the 0.2.0 docs.

- **`Cloudflare::Email::SecureMessageId`** — sign the outbound `Message-ID:`
  with HMAC-SHA256. The recipient's reply naturally carries the signed id
  in `In-Reply-To:`, which the inbound mailbox reads and verifies. Inspired
  by Cloudflare's Agents SDK `createSecureReplyEmailResolver` but stateless
  (no Durable Object storage). Payloads can carry meaningful JSON (thread
  id + user id + action) since Message-IDs don't hit the 64-char local-part
  limit. 30-day default max-age. Verified end-to-end against live Cloudflare
  with a 191-char signed Message-ID carrying a 4-field JSON payload.
- **`bin/rails cloudflare:email:provision_catchall DOMAIN=...`** — one-shot
  catch-all rule setup for a zone. Useful for bounce handling, dev
  subdomains, and alias routing.
- **`Cloudflare::Email::Credentials`** — unified credential lookup: Rails
  credentials first, then `CLOUDFLARE_*` env vars. Supports both workflows
  (credentials.yml.enc AND `.env` / platform secret stores).
- **Two-token split** — tasks that need higher privilege (deploy_worker,
  provision_route, dev) now read `management_token` and fall back to
  `api_token`. Runtime ActionMailer delivery keeps using `api_token`.
  Production: split them. Dev: one token works fine.
- **Doctor checks token split** and reports a warning for single-token setups.
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
