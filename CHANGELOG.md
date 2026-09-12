# Changelog

## Unreleased

- Add optional domain catch-all receiving on an existing active mailbox address,
  with explicit verification evidence and a unique active catch-all constraint.
  Exact registered addresses always win, including rejected inactive addresses;
  unknown local parts retain their actual envelope recipient without new aliases.
  Destination snapshots identify fallback, while sending stays exact-address only.
  A separate generator upgrades existing mailbox schemas; catch-all is never
  enabled automatically.

- Allow production Rails schema preloading to boot without a selected tenant.
  Tenant model pool access still fails closed with
  `Cloudflare::Email::ActiveRecord::TenantConnectionUnavailable`, an
  `ActiveRecord::ConnectionNotEstablished` error retaining the original
  `ConfigurationError` as its cause. No default tenant is selected.

- Add a reusable Worker `relayEmail` pipeline with host backend/header policies,
  bounded raw reads, optional fail-open archive hooks, safe HTTP outcomes and
  deadlines. `archiveEmail` writes raw bytes and envelope metadata to an optional
  R2 bucket. Default and custom forwarding share the same HTTP transport.
- Keep provider authentication interpretation, archive keys, retry decisions and
  fallback destinations with the host; existing default v2/v3 forwarding remains
  compatible. Archive deadlines bound waiting but cannot cancel an in-flight write.

- Add `Mailboxes.with_recipient` for active-address resolution and immutable
  destination context with host-owned persistence, without ActionMailbox.
- Yield the same destination from `Mailboxes.receive` so apps can link their
  business records while retaining gem-managed raw email, metadata and membership
  persistence. Host exceptions propagate instead of being reported as missing
  mailbox records; existing no-argument receive blocks continue to work.

- Add a bounded, Rails-independent `Ingress.verify` API for existing ingestion
  pipelines, with optional ActionMailbox persistence and tenant registry routing.
- Add opt-in v3 signatures for provider metadata supplied by custom Workers.
  Metadata is authenticated transport evidence, not proof of sender authenticity.
  Default Worker forwarding remains v2; upgrade Rails before enabling v3.
- Verify signatures against exact timestamp header bytes; decimal parsing is
  used only for freshness. The bundled Worker's timestamp format is unchanged.
- Add GET-only `cloudflare:email:check_route` diagnostics for exact receiving-domain
  DNS and Worker routing. Reports uncertainty without changing configuration or
  claiming live delivery is verified.

- Add an opt-in server-rendered mailbox management engine with host authentication,
  mailbox/domain scoping and per-action permissions. Manage mailboxes and aliases,
  suspend/resume, preview plain-text messages and mark read/archive without
  JavaScript or asset pipeline dependencies. The engine is never mounted by default.

- Fix managed domain and address activation in Rails apps with strict readonly
  attributes enabled. Normalize immutable identities only when creating records;
  later lifecycle updates retain the original domain and address.

## 0.2.0 — 2026-09-11

- Add optional managed mailboxes: domain directory, addresses/aliases, lifecycle,
  incoming memberships, read/archive/purge APIs and raw-mail retention.
- Add explicit tenant connections, tenant-aware framework and mailbox jobs,
  mailbox-authorized outbox sends, shared event intake/correlation and recovery.
  Verify separate SQLite databases and actual `activerecord-tenanted` integration;
  no new runtime dependency for plain Ruby consumers.
- Add a mailbox generator with separate shared/tenant migration paths and
  user guides for mailbox management and database tenancy.

- Bound Rails and Worker inbound reads to 25 MiB by default; reject malformed or
  stale signing headers before reading MIME. Require HTTPS remote endpoints.
- Restrict the development tunnel to email ingress and require a running guard;
  redact client inspection, retry logs, and generated mailbox logging.
- Validate delivery-event schemas, preserve receipt evidence through ordinary
  ActiveRecord updates, and tighten provider acceptance response handling.
- Remove Rails 7.1 support, update patched Rails/SQLite test floors, and audit
  resolved Ruby dependencies in CI. See the dated security verification report.

- Add an optional durable Rails outbox: immutable MIME/envelope snapshots,
  account-scoped operation keys, committed send claims, per-recipient acceptance
  evidence, blocked uncertain retries, and audited subset reconciliation.
- Add `Outbox.prepare_mail`, identity-only `SendJob`, replay jobs/tasks and
  `DeliveryEvents` to correlate provider events and update recipient lifecycle
  state transactionally. Normalize receipt message IDs for indexed replay.
- Verify concurrent sends and event projection on PostgreSQL as well as SQLite;
  include process termination, partial outcomes and post-acceptance persistence
  failures. The inbox uses the shared ledger with preserved historical records.

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
