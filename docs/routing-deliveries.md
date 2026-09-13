# Confirm delivery to verified Routing destinations

Cloudflare can deliver mail to a verified Email Routing destination through Routing without producing an Email Sending delivery callback. You can keep using the recipient's normal address. Do not remove its verified destination or rewrite the recipient to obtain a callback.

The optional Routing Analytics integration confirms **positive delivery to the receiving mail server** from authenticated Cloudflare analytics. It does not prove inbox placement or that a person read the message. Missing analytics leave the outcome unresolved; they never authorize a resend or provider fallback.

## Enable it

The plain Ruby client needs no Rails or Active Record dependency:

```ruby
require "cloudflare/email/routing_analytics"

client = Cloudflare::Email::RoutingAnalytics::Client.new(
  account_id: ENV.fetch("CLOUDFLARE_ACCOUNT_ID"),
  zone_id: ENV.fetch("CLOUDFLARE_ANALYTICS_ZONE_ID"),
  api_token: ENV.fetch("CLOUDFLARE_ANALYTICS_TOKEN")
)
client.verify_account!
```

Use a separate token with **Zone Analytics Read and Zone Read**, restricted to the sending zone. The client verifies that the zone belongs to the supplied account before querying analytics. Keep sending and queue credentials separate. A token is never written into a receipt.

For durable Rails tracking, install the outbox first, then generate the additional receipt table:

```sh
bin/rails generate cloudflare:email:outbox # only if not already installed
bin/rails generate cloudflare:email:routing_tracking
bin/rails db:migrate
```

Receipts encrypt their JSON evidence using Rails Active Record Encryption. Configure the application's `active_record.encryption.primary_key`, `deterministic_key`, and `key_derivation_salt` before recording receipts (Rails' `db:encryption:init` task generates keys). Keep keys in credentials or protected environment configuration and back them up separately. There is no plaintext fallback enabled by this integration. Receipt metadata includes account and operation identifiers; protect the database and backups as usual.

The generated initializer explicitly requires `cloudflare/email/active_record/routing_deliveries`. Installing the gem alone enables no scheduler, network request, tracking table, or tenancy behavior.

## Collect and apply evidence

Run network requests outside database transactions. The durable outbox must have retained the accepted operation's SMTP envelope and provider Message-ID:

```ruby
tracking = Cloudflare::Email::ActiveRecord::RoutingDeliveries

client.delivery_evidence(
  message_id: delivery.provider_message_id,
  since: delivery.request_started_at,
  until_time: Time.now.utc
).each do |evidence|
  receipt = tracking.record(delivery: delivery, evidence: evidence)
  tracking.apply(receipt) do |saved_delivery, recipient|
    # Optional business projection using this same database connection.
    # Read recipient.state; do not send mail or call external services here.
  end
end
```

`record` commits the original evidence before projection. Repeating it returns the same receipt. A changed authentic event under the same identity, or association with another operation, raises an error. Query windows and other rows returned alongside that event may differ between polls without creating duplicate receipts. Client payloads retain the complete original response envelope, provider row, authenticated account/zone, source, and query window and are immutable through ordinary model updates.

`apply` returns `:applied`, including successful replay. It updates only a nonterminal recipient and marks the receipt applied in the same transaction. It preserves the accepted operation, envelope snapshot, and every existing terminal webhook fact, including a bounce. Thus `:applied` means evidence was processed; inspect the recipient's actual state. A later genuine Sending complaint continues to update the recipient through the existing Sending event API.

Callbacks run only when the recipient changes. Same-database callback errors roll back the recipient, business writes, and receipt completion together; the original pending receipt remains available. A callback must not send email or perform external effects.

This is not a webhook endpoint: accept evidence only from the authenticated client or your protected durable storage. Constructing an `Evidence` object validates its shape and correlation, not its provenance. Never deserialize arbitrary incoming request bodies into trusted analytics evidence.

## Retry projection fairly

```ruby
result = tracking.replay(account_id: account_id, limit: 100, after_id: saved_cursor)
result.errors.each do |failure|
  ErrorReporter.report(failure[:error], receipt_id: failure[:receipt_id])
end
save_cursor(result.finished ? 0 : result.after_id)
```

The batch is bounded to 1–1,000 receipts. Failed receipts advance the cursor, allowing later receipts to proceed. After a complete pass, reset the cursor and revisit failures. Errors remain visible in the return value; your application must report them. Supply the same optional projection callback when replaying. Give fresh analytics discovery a separate scheduling opportunity so repeated projection failures cannot starve new evidence. No database transaction is interrupted by an HTTP or polling timeout.

The client uses a five-second total network deadline, five-second socket timeouts, a 1,000,000-byte streamed response cap and no implicit HTTP retry. A failed request is visible to your scheduler. Queries returning 100 rows are rejected as potentially truncated; use a narrower historical window and retain existing unresolved records. Plan availability, analytics retention and sampling can limit what Cloudflare can prove.

## Deliberately conservative matching

The initial API requires exactly one accepted saved SMTP-envelope recipient, exactly one matching accepted operation in the account, matching sender and normalized provider Message-ID, and a nonempty provider session ID. The event must be `newEmail`, `delivered`, final, unsampled and not an NDR. Its timestamp must fall inside the requested historical window and at or after the saved request start, rounded down to Cloudflare's second precision.

MIME `To` and analytics `to` are never used as envelope identity. Multi-recipient operations, sampled rows, forwarding rows and missing events do not become guessed delivery or failure. Malformed, truncated, conflicting or wrongly scoped qualifying evidence raises. Terminal delivery can override an equal or later nonterminal observation; existing terminal facts stay intact.

## Tenant and cross-database applications

Multi-tenancy remains off by default. If enabled, use the existing `Tenancy.with` or `Mailboxes.for_tenant` context for every outbox and Routing receipt operation, and install the receipt migration in each tenant database. Record instances cannot be moved between tenant contexts. A separate analytics account does not select or authorize a tenant.

The gem checks provider-ID uniqueness inside the selected database. If one Cloudflare account spans several tenant databases, the host must also enforce account-wide provider-ID uniqueness in its shared directory or ledger before calling `record`. Tenant-local lookup alone cannot establish that a matching operation is unique across independent databases.

An application may reserve an explicit physical storage key for system mail, such as `_system_outbound`, using its existing tenant provisioning and backup process. That storage key is not an organization or authorization identity. Keep nil tenant context fail-closed; do not silently map it to shared storage. Reserve and validate the key in the host application so a customer cannot claim it.

For business records on another database, keep the host's own durable intake/projection record. Commit the gem evidence and projection in the selected tenant database, then finish the host projection. If the second commit fails, replay the same gem evidence and finish the host work independently. The gem's callback will not run again after its receipt was applied. There is no distributed transaction or exactly-once external effect guarantee.

Cloudflare references: [Email event subscriptions](https://developers.cloudflare.com/email-service/platform/event-subscriptions/) and [metrics and analytics](https://developers.cloudflare.com/email-service/observability/metrics-analytics/).
