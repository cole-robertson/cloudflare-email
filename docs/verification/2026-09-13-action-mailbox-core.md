# Action Mailbox composition verification

## Independent review follow-up

The independent architecture review of `63660eb` confirmed the Rails/core/provider
split and reproduced a missing inbound membership index with SQLite's query planner.
The follow-up adds that index to both installers and supplies `mailbox_kit:upgrade`
for existing schemas. The generator fixture verifies indexed lookup, existing
membership preservation and repeat application. It passes 4 tests / 27 assertions.

Cloudflare configuration now delegates shared validation to the core, and its
session behavior is an explicit integration module. Handler overrides retain
their existing extension point. The short core README links to packaged
integration and upgrade guides.

After these changes, the full suite passes 289 tests / 1,151 assertions. Package
verification passes for Rails-free Cloudflare, packaged ingress/outbound/tenancy,
and an independent Rails consumer without Cloudflare in its bundle.

This is local/package verification, not a Rebulk production rollout. Automatic
model-owner lifecycle bindings and a universal outbound adapter framework remain
outside this change. Existing application acceptance, ownership and business
processing claims must be retained.

Mailbox Kit now treats `ActionMailbox::InboundEmail` as the original email record.
The kit's `Message` remains an inbox membership with read/archive state; no new
raw-email table, parser, routing job or processing-status model was introduced.

## Verified behavior

- `Mailboxes.receive(recipient:, source:)` resolves the trusted receiving scope
  before Rails persistence, and attaches the existing record on source replay.
  Identical source in two inboxes of one tenant produces one Rails email, two
  memberships and one routing job. Read state remains independent per inbox.
- Identical source in different tenants sharing a database produces distinct
  Rails records/jobs. `Session#attach` rejects a row already associated with a
  different tenant, and resolves IDs only inside the selected connection.
- `Session#attach(recipient:, inbound_email_id:)` supports already-stored Rails
  mail. It is idempotent per mailbox/email, preserves alias reservations and
  refuses suspended addresses or missing records.
- The stock Rails Postmark ingress was exercised through HTTP in the isolated
  Rails fixture. Duplicate webhook payloads produced one Rails email; explicit
  host-authorized attachment created its inbox membership without reprocessing.
- Cloudflare retains its prior authenticated envelope/metadata identity and
  stable Message-ID fallback. Its controller uses `receive_into_mailbox!` and
  repairs missing membership on replay without re-enqueueing Rails routing.
  The older `persist_action_mailbox!` still returns nil on duplicate delivery.
- Rails' `incinerate = false` prevents automatic cleanup scheduling without a
  membership. With normal cleanup enabled, aged processed unassociated mail is
  removed while inbox-associated mail survives. The guard uses Rails' public
  inbound-email load hook and the same row lock as attachment and purge.
- Removing one of two memberships preserves the shared raw email; removing the
  last through explicit purge removes it. Failed membership persistence rolls
  back Rails database records and prevents a routing enqueue.
- PostgreSQL deliveries were synchronized at Rails creation to force a unique
  conflict. Both calls completed with one inbound record, one membership, one
  Active Storage blob record and one routing job. A savepoint rollback keeps the
  losing transaction usable before looking up the winning record.

## Checks

- Full Ruby suite: 289 top-level tests, 1,151 assertions passed. Integration
  subprocesses exercise the additional Rails behavior rather than inflating these
  top-level counts.
- `script/verify_package.rb`: both gem archives built; Rails-free Cloudflare
  consumer, packaged Cloudflare integration and independent core-only Rails
  consumer passed. The independent bundle contains no Cloudflare gem.
- PostgreSQL inbound suite: 25 tests, 273 assertions passed on a disposable local
  PostgreSQL 15 instance. CI runs the same suite against PostgreSQL 16 alongside
  the existing outbox tests.
- SQLite core/compatibility, separate-tenant ingress and custom ingress regression
  suites were exercised locally. CI covers the supported Ruby/Rails matrix.

Run the PostgreSQL check only against a disposable database:

```sh
BUNDLE_GEMFILE=gemfiles/postgres.gemfile \
POSTGRES_TEST_URL=postgres://localhost/cloudflare_email_test \
bundle exec ruby script/verify_postgres_inbound.rb
```

The script creates a unique schema and drops that schema when its fixture exits.

## Limits

The Postmark test is a fixed, authorized single-database route, not a live
Postmark deployment or a complete dynamic-tenant provider adapter. The caller
must authenticate ingress and authorize the envelope recipient and inbound ID;
MIME To/X-Original-To headers are not tenant entitlement. Tenant selection after
ingress cannot relocate raw mail already persisted to another database.

Raw blob uploads and external side effects are not made transactional by Active
Record. This check does not establish exactly-once business effects, provider
outage recovery, lost-job recovery, or live delivery. Existing Cloudflare durable
transport remains responsible for its outage/retry behavior. Owner lifecycle
macros and a general outbound adapter framework are separate work.
