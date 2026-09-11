# What cloudflare-email does

cloudflare-email connects your Ruby or Rails application to Cloudflare's email
services. You can use just the sending client, add incoming mail, or build a
mailbox on top of the optional database-backed delivery tools.

Start with [Getting started](getting-started.md) for working examples. These
features describe the unreleased **0.2.0** code; use the commit pinned in that
guide until the release is published.

## Choose the pieces you need

| You want to… | Use | What you get |
| --- | --- | --- |
| Create managed inboxes in code | Optional `Mailboxes` module | Named mailboxes, aliases, ownership references, read/archive state and retained raw mail |
| Isolate organizations in separate databases | Optional `Tenancy` adapter | Configurable ActiveRecord base, tenant-aware jobs and shared-to-tenant event replay; tested with SQLite and `activerecord-tenanted` |
| Send from an ordinary Ruby program | `Cloudflare::Email::Client` | Structured messages or complete raw MIME; no Rails/database required |
| Send existing Rails mailers | ActionMailer delivery method | Your mailer templates, attachments, multipart bodies, cc/bcc and reply headers sent through Cloudflare |
| Receive email in Rails | Email Worker + ActionMailbox | Unchanged raw MIME, attachments, authenticated SMTP envelope metadata and duplicate handling |
| Develop against real incoming email locally | `cloudflare:email:dev` | A temporary tunnel restricted to your email ingress |
| Save an email before sending it | Optional ActiveRecord outbox | Immutable message snapshot, saved recipients, a send claim, and per-recipient results |
| Avoid accidentally resending after a crash or timeout | `SendJob` + outbox | Jobs use the saved operation identity; uncertain attempts stay blocked for review |
| Track delivery, bounce or complaint updates | `EventConsumer` + Cloudflare Queue | Validated lifecycle events, account/domain checks and acknowledgement after successful handling |
| Avoid building your own event ledger | Optional tracking tables | Durable receipts, duplicate/conflict detection, unmatched-event storage and replay |
| Connect events to outbox recipients | `DeliveryEvents` | Account/message/recipient matching, event ordering and callbacks for your app's records |
| Investigate an uncertain send | Recovery tasks + `Outbox.reconcile` | Operator-supplied evidence and an audit trail; no automatic resend based on elapsed time |
| Match replies to earlier messages | Provider message IDs + `MessageId.normalize` | A consistent lookup key for your app's conversations |
| Observe email processing | ActiveSupport notifications + `doctor` | Send/ingress/event/outbox instrumentation and configuration diagnostics |
| Deploy receiving infrastructure | Ruby deployer and routing tasks | Environment-specific Workers, ingress secrets, address routes and DNS preflight checks |

## SQLite works

The optional receipt and outbox tables work with **SQLite**. Keep your existing
Rails SQLite database; PostgreSQL is optional, and both adapters have concurrency
coverage. The gem uses ActiveRecord and does not install a separate database
service. You still choose a durable Rails job backend and run its workers.

Database locking conflicts can require a job retry. A retry uses the existing
outbox identity; it does not clear an uncertain send claim. Keep application
writes and gem callbacks on the same database connection when they must commit
together. See [outbox setup](outbox.md).

## Understand the different kinds of success

| Result | What it tells you |
| --- | --- |
| Successful API request | Cloudflare returned a successful response; inspect recipient outcomes too |
| `response.accepted?` | There is evidence of acceptance for at least part of the send |
| Outbox `accepted` | Every recipient has acceptance evidence |
| Outbox `partial` | Some recipients have acceptance evidence; the others need individual attention |
| Delivery event `delivered` | The recipient's server accepted the email; this is not a read receipt |
| Ingress HTTP 200 | Rails stored the message or recognized a duplicate; mailbox processing happens separately |

Sending, receiving and delivery tracking are separate Cloudflare setups. A
working sending domain does not automatically enable incoming routes or queue
subscriptions. The [getting-started guide](getting-started.md) walks through each.

## Protections included

Incoming requests use v2 HMAC signatures covering the timestamp, SMTP sender,
SMTP recipient and raw message. Rails checks a five-minute timestamp window.
Identical MIME retried for the same recipient is deduplicated; delivery to a
different recipient is stored separately.

Rails and the Worker default to a **25 MiB raw incoming message limit**. Both
support a positive `MAX_EMAIL_BYTES` override. Remote endpoints require HTTPS,
the Worker refuses redirects and limits its Rails request to 15 seconds, and
the development tunnel only routes ingress POSTs. Client inspection and default
retry/mailbox logging omit sensitive details.

The outbox preserves the rendered message and acceptance evidence, blocks
ambiguous resend attempts, and records reconciliation decisions. Delivery-event
validation rejects malformed schema fields; original receipt identity and
payload are read-only through normal ActiveRecord updates. These safeguards do
not make database administrators untrusted or provide exactly-once delivery.

See [managed mailbox setup](mailboxes.md) for the application-facing API and
[activerecord-tenanted](activerecord-tenanted.md) for separate SQLite databases.

## What belongs in your mailbox application

The gem supplies email infrastructure and optional managed mailbox records.
Your app supplies users, mailbox permissions, conversation records, custom folders, search, compose screens,
drafts and any AI review or approval workflow. It also decides unsubscribe and
recipient eligibility policy. The gem does not supply an inbox UI or AI agent.

An authenticated SMTP envelope tells your app which address Cloudflare received
the message for. It does not prove the human sender's identity. Reply correlation
also does not authorize access to a conversation. Apply your app's permissions
before displaying mail or sending a reply.

You configure Cloudflare domains/DNS, queue subscriptions, durable jobs,
monitoring, storage protection and retention. Inbound mail is not durably
buffered by the Worker during a Rails outage. See [architecture](architecture.md)
for the full boundary and [security guidance](../SECURITY.md) for deployment.

## Where to go next

- [Build your first integration](getting-started.md)
- [Use plain Ruby, attachments or raw MIME](../README.md#plain-ruby)
- [Configure client retries and errors](../README.md#retry-and-configuration)
- [Set up event polling and durable receipts](delivery-events.md)
- [Recover saved outbound operations](outbox.md)
- [Correlate replies](thread-correlation.md)
- [Use Cloudflare SMTP instead of the HTTP delivery method](../README.md#smtp-alternative)
- [Troubleshoot your setup](troubleshooting.md)
