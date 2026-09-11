# Gem and inbox responsibilities

The Cloudflare gem supplies email transport and reusable delivery infrastructure.
The inbox application supplies a product built on that infrastructure. Plain Ruby
users should not need Rails or a database. Rails users should be able to opt into
durable infrastructure without copying the reference inbox's models and services.

## Implemented in this extraction

| Gem capability | Application responsibility |
| --- | --- |
| Structured/raw sending and ActionMailer transport | Compose UI, recipients and send authorization |
| `Response#accepted?`, plus individual recipient outcomes | Handle partial acceptance without resending accepted recipients |
| Authenticated v2 ingress and recipient-scoped deduplication | Map trusted recipient to an authorized mailbox |
| `MessageId.normalize` and returned provider IDs | Store conversation membership and scope reply lookups |
| Queue decoding, validation and ACK | Queue/subscription setup and recurring execution |
| Optional ActiveRecord event receipts, deduplication and replay | Match event to an application send and update product records |
| `DeliveryEvent#supersedes?` | Correlate account/message/recipient before applying an event |

The ActiveRecord adapter is explicit opt-in. Its generator installs a receipt table
and initializer; the default plain Ruby client does not load ActiveRecord. Its
handler applies application writes on the same database connection as the receipt.
It does not wrap HTTP calls or other external effects in a database transaction.

Version 0.2 is a preproduction break: v1 ingress and signed Message-ID tokens are
removed. Cloudflare's documented queue encodings and recipient-response forms are
provider contracts, so accepting them is not obsolete application compatibility.
Historical verification reports describe their dated runs, not the current API.

## Next extraction: durable outbound delivery

The inbox's send claim, immutable attempt snapshot, uncertainty handling and
reconciliation are reusable infrastructure in principle. They still reside in the
application in this change. Moving only its models would leave consumers copying
the critical orchestration, so the next extraction should provide one opt-in
outbound operation API with these guarantees:

1. Claim an application-supplied operation key scoped to an account using a unique
   index before sending; repeated or concurrent calls cannot silently resend.
2. Persist immutable rendered MIME and envelope recipients before the network
   request. Track each recipient separately, including partial acceptance.
3. Separate preparation failures from ambiguous outcomes. A timeout, process death
   or persistence failure after acceptance keeps the operation blocked. An elapsed
   timeout alone never proves the message was not sent.
4. Persist returned provider IDs and recipient outcomes, then replay unmatched
   delivery events. Never claim the provider request and database commit are atomic.
5. Expose audited reconciliation with caller-supplied actor/reason and evidence.
   The application authorizes the operator; the gem enforces legal transitions.
6. Provide jobs/tasks and notifications that preserve the same claim on retries.
   Include migration/import support for the reference inbox's existing attempts.

Before this becomes the default, test two concurrent senders, process termination
during the request, acceptance followed by failed persistence, partial recipient
acceptance, event-before-response, and recovery without a duplicate send. Exercise
SQLite and PostgreSQL concurrency. Existing inbox recovery tests are a useful
baseline, not evidence that an unimplemented generic ledger already works.

## Keep in the inbox product

Users, tenancy, mailbox ownership, conversations, folders, search and UI remain in
the inbox. AI context, review flags, approval thresholds, auto-send policy and
operator permissions also stay there. Suppression/unsubscribe requirements depend
on message purpose and application policy; expose provider outcomes, but do not
silently impose a marketing subscription model on transactional mail.

A reusable inbox Rails engine or starter can later package common product setup.
It should consume these gem APIs instead of maintaining another transport/receipt
implementation. A new separate gem is unnecessary for the current optional adapter.
