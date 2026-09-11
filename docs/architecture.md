# Gem and inbox responsibilities

The Cloudflare gem supplies email transport and reusable delivery infrastructure.
The inbox application supplies a product built on that infrastructure. Plain Ruby
users should not need Rails or a database. Rails users should be able to opt into
durable infrastructure without copying the reference inbox's models and services.

## Implemented in this extraction

| Gem capability | Application responsibility |
| --- | --- |
| Optional mailbox/address directory and tenant connection adapter | Authorize domain ownership, provision tenant databases and grant user access |
| Mailbox memberships, read/archive state and retained raw mail | Inbox UI, retention schedule and explicit purge policy |
| Shared event intake, tenant correlation and tenant-aware jobs | Durable queue workers, scheduled recovery and schema rollout to every tenant |
| Structured/raw sending and ActionMailer transport | Compose UI, recipients and send authorization |
| `Response#accepted?`, plus individual recipient outcomes | Handle partial acceptance without resending accepted recipients |
| Authenticated v2 ingress and recipient-scoped deduplication | Map trusted recipient to an authorized mailbox |
| `MessageId.normalize` and returned provider IDs | Store conversation membership and scope reply lookups |
| Queue decoding, validation and ACK | Queue/subscription setup and recurring execution |
| Optional ActiveRecord event receipts, deduplication and indexed replay | Configure queue polling and receipt retention |
| Immutable outbox snapshots, send claims, per-recipient outcomes | Authorize sending and choose a stable operation key |
| `DeliveryEvents` account/message/recipient correlation and ordering | Transactional callback to update product records |
| Send/replay jobs, recovery tasks and audited reconciliation | Authorize operators and provide evidence of provider outcome |

The ActiveRecord adapter is explicit opt-in. Its generator installs a receipt table
and initializer; the default plain Ruby client does not load ActiveRecord. Its
handler applies application writes on the same database connection as the receipt.
It does not wrap HTTP calls or other external effects in a database transaction.

Version 0.2 is a preproduction break: v1 ingress and signed Message-ID tokens are
removed. Cloudflare's documented queue encodings and recipient-response forms are
provider contracts, so accepting them is not obsolete application compatibility.
Historical verification reports describe their dated runs, not the current API.

## Implemented: durable outbound delivery

The inbox now uses the gem's ledger tables and orchestration. Its model subclasses
add application message associations and display snapshots; they do not maintain
a second sending ledger. See the [outbox guide](outbox.md) for installation and API.

1. Claim an application-supplied operation key scoped to an account using a unique
   index before sending; repeated or concurrent calls cannot silently resend.
2. Persist immutable rendered MIME and envelope recipients before the network
   request. Track each recipient separately, including partial acceptance.
3. Separate preparation failures from ambiguous outcomes. A timeout, process death
   or persistence failure after acceptance keeps the operation blocked. An elapsed
   timeout alone never proves the message was not sent.
4. Persist validated provider IDs and recipient acceptance outcomes separately
   from later lifecycle events. Replay correlates account, message and recipient;
   conflicting IDs remain uncertain. The network and database are not atomic.
5. Expose audited reconciliation with caller-supplied actor/reason and evidence.
   The application authorizes the operator; the gem enforces legal transitions.
6. Provide jobs/tasks and notifications that preserve the same claim on retries.
   Include migration/import support for the reference inbox's existing attempts.

The suite exercises concurrent senders, actual process termination, acceptance
followed by persistence failure, partial recipients, event-before-response,
out-of-order events, callbacks that roll back, and recovery without a duplicate
send. PostgreSQL and SQLite run separate concurrency checks. Inbox HTTP and browser
workflows use the shared implementation, with controlled local provider responses.

Historic attempts did not preserve rendered MIME. Their import retains available
bodies, IDs, outcomes and operator evidence and marks reconstructed snapshots.
Unknown historical outcomes remain blocked. No migration claims to recreate the
exact bytes of a previously sent message.

## Operational completion

The reference inbox supplies a functional mailbox product over these APIs. Before
production use, configure sending DNS and receiving routes, queue subscriptions
and dead-letter handling, durable Rails jobs, receipt/MIME retention and backups,
and monitoring for prepared/sending/unknown/partial operations. Exercise live
external mailbox delivery and recovery with the deployed revision. Installation
does not automatically provision domains or deploy infrastructure.

Current limitations are deliberate and visible: no provider exactly-once API,
no automatic resend of uncertain or rejected operations, no multi-provider-ID
operation (conflicting IDs require review), and no durable inbound Worker buffer.
A prepared operation can be dispatched using its existing identity after a job
enqueue failure; sending/unknown operations require evidence-based reconciliation.
Notifications indicate method execution and may run inside an outer transaction;
the durable database record is authoritative.

## Keep in the inbox product

Users, tenancy, mailbox ownership, conversations, folders, search and UI remain in
the inbox. AI context, review flags, approval thresholds, auto-send policy and
operator permissions also stay there. Suppression/unsubscribe requirements depend
on message purpose and application policy; expose provider outcomes, but do not
silently impose a marketing subscription model on transactional mail.

The optional [mailbox module](mailboxes.md) now packages mailbox persistence and
address management over the existing transport/receipt APIs. It includes a
[tenant adapter](activerecord-tenanted.md), without adding a tenant library to
the plain Ruby client. The optional [management engine](management-engine.md)
consumes these same APIs with host-supplied authentication and authorization.
Full inbox products can continue using them through their own frontends.
