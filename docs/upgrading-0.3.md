# Upgrade from 0.2 to 0.3

Update your Gemfile to `gem "cloudflare-email", "~> 0.3.0"`, run
`bundle update cloudflare-email`, and deploy Rails first. Updating the gem does
not replace your deployed Worker, change DNS, or enable optional mailbox features.
If you are upgrading from 0.1, complete the [0.2 upgrade](upgrading-0.2.md) too.

## Receiving mail while Rails is down

New installations can use the [Deploy to Cloudflare template](../templates/deploy-to-cloudflare/README.md)
to provision the Worker resources through Cloudflare's setup form. Existing
installations should preserve their resources and pending mail using the steps below.

The bundled Worker now stores inbound mail in private R2 before accepting it,
then delivers through a Queue with scheduled recovery. Before deploying it:

1. Create an R2 bucket and Queue for each environment.
2. Configure the `INBOUND_EMAIL_STORE` binding, `INBOUND_EMAIL_QUEUE` producer
   and consumer, and once-per-minute cron from the bundled `wrangler.toml`.
3. Preserve your ingress URL and shared secret. Deploy with Wrangler first;
   the Rails deploy task does not provision infrastructure.
4. Verify that mail queues during a Rails outage, drains after recovery, and
   retries without duplicating application records. Monitor pending mail and age.

Follow the [durable delivery guide](../templates/worker/docs/durable-inbound.md)
for commands, retention requirements, capacity limits, and recovery behavior.
Missing infrastructure fails visibly. To deliberately retain single-attempt
delivery, explicitly select `INBOUND_DELIVERY_MODE=direct` before deploying.
Direct mode cannot buffer outages. Keep existing bindings and cron so previously
stored mail continues to drain. The old `DURABLE_INBOUND_ENABLED` flag is removed.

Messages without a parseable Message-ID now receive a deterministic fallback
across Rails hosts. Historical records created with the old hostname-dependent
fallback may duplicate on replay; reconcile old archives before replaying them.
Retain deduplication records for your recovery horizon and make app processing
idempotent. Durable transport is not an exactly-once delivery guarantee.

## Optional features

- [Management engine](management-engine.md): mount a server-rendered mailbox UI
  with host authentication, scopes, and permissions. It is not mounted automatically.
- [Mailboxes](mailboxes.md): enable domain catch-all explicitly on an existing
  active address. Follow the catch-all schema upgrade instructions; exact
  registered addresses still take precedence, and sending remains exact-address only.
- [Custom ingestion](custom-ingress.md): integrate verified envelopes and raw
  persistence into an existing app. Deploy Rails before enabling v3 metadata
  signatures in a custom Worker; ordinary v2 forwarding remains supported.
- [Routing delivery confirmation](routing-deliveries.md): configure separate
  analytics credentials and durable receipts if needed. API acceptance alone
  is not proof of delivery, and ambiguous evidence must not trigger a resend.

Database tenancy remains opt-in. Existing tenant-enabled applications can now
preload their schemas without selecting a tenant; actual mailbox access still
requires explicit tenant context. No new database tables are required merely to
upgrade the gem or use the durable inbound Worker.
