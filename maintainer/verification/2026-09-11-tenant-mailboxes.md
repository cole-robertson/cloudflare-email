# Optional mailboxes and tenant support — 2026-09-11

Implementation source: `4273c5ac10cb87d5e5610acc6a4e69c55d94a42f`.
The guides and installation pin may receive subsequent documentation-only updates.

## Implemented

- Explicit optional tenant adapter and configurable model base for the existing
  outbox/receipt models and new tenant mailbox models. Plain Ruby remains independent.
- Shared receiving-domain directory and tenant mailboxes, aliases, owner references,
  lifecycle, inbound memberships, read/archive state and explicit purge.
- Full HMAC verification before recipient-to-tenant resolution, followed by
  same-connection ActionMailbox/ActiveStorage persistence and membership storage.
- Scoped mailbox sender checks and identity-only send jobs using the existing
  immutable outbox, callbacks, reconciliation and conservative retry behavior.
- Shared event intake before ACK, account/message/recipient correlation to a
  tenant outbox, tenant commit before shared completion, and bounded recovery jobs.
- Tenant serialization before framework GlobalID lookup; missing/conflicting
  tenant metadata rejected. Managed raw mail retained against normal incineration.
- Composed generator with separate tenant/shared migration paths and optional
  `activerecord-tenanted` integration guide/bundle/CI job.

## Local verification

Ruby 3.4.1 / Rails 8.1.3.1 unless noted:

| Check | Result |
| --- | --- |
| Full `bundle exec rake test` | 212 tests, 758 assertions, no failures/errors/skips |
| Tenant connection and job subprocess | 11 tests, 54 assertions; physical SQLite shards with overlapping IDs, host-only framework job capture and context restoration |
| Default job-context subprocess | 3 tests, 7 assertions; ordinary untagged jobs preserved without database tenancy |
| Mailbox service subprocess | 16 tests, 92 assertions; two fixed SQLite tenant pools plus shared directory |
| Shared event subprocess | 8 tests, 28 assertions; also checked on Rails 7.2 |
| Real Rails mailbox ingress subprocess | 4 tests, 29 assertions; signed recipient routing, raw storage, jobs, aliases, deduplication, unavailable destinations, retention and purge |
| Actual `activerecord-tenanted` 0.8 integration | 3 tests, 23 assertions; real tenant provisioning/migrations, isolation, context and GlobalID checks |
| Generator checks | Fresh single-DB and separate shared/tenant SQLite installs, migration ordering and initializer syntax |
| Packaged gem | Isolated Ruby consumer; Rails install/ingress/outbox checks; new tenant ingress, jobs, retention and all mailbox migrations from extracted package |
| Local workerd → Rails | Existing real runtime fixture passed, including raw bytes, routing, duplicates, invalid credentials, redirects and timeout |

Top-level test totals include subprocess wrapper assertions; detailed subprocess
counts above describe their internal checks and are not additional top-level tests.
The service suite includes concurrent claims producing one provider request,
callback rollback, retry/recovery without resending, reconcile rollback, pagination,
suspension after enqueue, caller operation-key isolation and sender/account checks.
Event tests include event-before-response, conflicting identities, cross-tenant
correlation ambiguity, tenant-commit/shared-failure replay, and callback rollback.

The optional tenant dependency resolution passed bundler-audit. CI additionally
runs the supported Ruby/Rails matrix, PostgreSQL outbox checks and Worker checks.
Check the PR's CI for results on its latest revision.

## Operational boundaries

No production Worker, domain/DNS, inbox or Rebulk deployment changed. No real
email was sent by these checks. The new Worker-to-mailbox path uses the existing
v2 signature contract; live customer subdomain provisioning was not exercised.
Rebulk's existing ingest/communication records and sender-authentication policy
still require a separate, explicit application adoption project.

Directory activation records authorized operator evidence, not independent
domain verification. Application permissions select tenant and mailbox access;
raw ActiveRecord and administrative directory methods are privileged interfaces.
Database keys and queue payloads must come from trusted application state.

Framework records must share the configured tenant connection. Drain old
ActionMailbox/ActiveStorage jobs before enabling database tenancy because old
payloads without the new metadata cannot safely be guessed. Mailbox memberships
retain raw mail until explicit purge, so applications must define a retention
policy and monitor storage usage.

Queue intake and tenant projection use separate commits with idempotent recovery,
not a distributed transaction. Schedule polling, shared replay and per-tenant
recovery. Unknown provider outcomes stay blocked; no exactly-once guarantee or
automatic resend is added. Existing outbox PostgreSQL behavior remains covered;
the new mailbox/tenant integration's direct database evidence is SQLite.
