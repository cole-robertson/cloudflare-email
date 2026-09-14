# Upgrading existing mailbox installations

The extracted core keeps existing `cloudflare_email_` tables, record IDs, public
Cloudflare constants and tenant job payloads. Keep your initializer, mounted
engine, Worker and application processing code. Do not run `mailbox_kit:install`
or the Cloudflare mailbox installer over existing mailbox tables.

After updating the gems, generate the index and receiving-domain migrations:

```sh
bin/rails generate mailbox_kit:upgrade
bin/rails db:migrate
```

For separate tenant databases:

```sh
bin/rails generate mailbox_kit:upgrade --tenant-migrations-path=db/tenant_migrate --directory-migrations-path=db/migrate
```

Apply the index migration to every database containing mailbox messages using your
application's tenant migration runner. It does not belong in the shared domain
directory database. The migration preserves messages and skips an existing
single-column inbound index. New installers already include this index.

Apply `AllowProviderNeutralReceivingDomains` to the shared directory database.
It allows a null receiving-domain account ID, preserving existing account values.
Receiving-only registration requires no Cloudflare account; sending still requires
an explicit account and verified sending domain. On SQLite this schema change can
rebuild the directory table, so use your normal migration window.

Index creation can block writes on large tables. Plan its application according
to your database's normal migration procedure; PostgreSQL installations needing
online builds can adapt it to `algorithm: :concurrently` with
`disable_ddl_transaction!`.

## Verify the application upgrade

1. Receive a message through the existing authenticated provider integration.
2. Confirm it appears in the right inbox and runs the existing business handler.
3. Replay the delivery and confirm no duplicate business effects.
4. Check authorized and unauthorized UI access, read/archive actions, and retention.
5. For separate databases, exercise tenant routing and processing jobs in two tenants.

Keep your application's sender acceptance, ownership reconciliation and processing
claims. Rails processing status does not replace these business policies.

## Adding Cloudflare to a core-only application

The core's mailbox schema alone does not supply Cloudflare's outbox and event
tables. Add those provider tables and sending configuration explicitly using the
Cloudflare integration guide; do not run both complete installers against the
same database. Arbitrary subdomain receiving does not authorize sending from those
subdomains: verify each Cloudflare sending domain separately.

## Versions

Cloudflare Email 0.4.0 depends on Mailbox Kit 0.1.x and installs it automatically.
Core-only applications can install `gem "mailbox-kit", "~> 0.1.0"` directly.
Upgrade and verify your application's email flows before a wider rollout.
