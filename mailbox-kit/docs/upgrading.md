# Upgrading existing mailbox installations

The extracted core keeps existing `cloudflare_email_` tables, record IDs, public
Cloudflare constants and tenant job payloads. Keep your initializer, mounted
engine, Worker and application processing code. Do not run `mailbox_kit:install`
or the Cloudflare mailbox installer over existing mailbox tables.

After updating the gems, generate the additive index migration:

```sh
bin/rails generate mailbox_kit:upgrade
bin/rails db:migrate
```

For separate tenant databases:

```sh
bin/rails generate mailbox_kit:upgrade --tenant-migrations-path=db/tenant_migrate
```

Apply that migration to every database containing mailbox messages using your
application's tenant migration runner. It does not belong in the shared domain
directory database. The migration preserves messages and skips an existing
single-column inbound index. New installers already include this index.

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

## Release order

This extraction is unreleased. Publish `mailbox-kit` first, then a Cloudflare
release depending on it. A passing local suite is not a production cutover;
upgrade and verify a dogfood application before a wider rollout.
