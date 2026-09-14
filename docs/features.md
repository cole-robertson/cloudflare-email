# Features

Cloudflare Email handles sending, receiving, and delivery tracking. Mailbox Kit
adds persistent inboxes and a management UI. Start with the
[Rails quickstart](getting-started.md).

## Sending

- Use existing Action Mailer templates or the plain Ruby client.
- Send text, HTML, attachments, multipart messages, cc/bcc, and replies.
- Save outgoing messages in a [durable outbox](outbox.md) with a history of attempts and recipient outcomes.
- Retry jobs using the saved send operation; uncertain sends stay available for review.
- Track delivered, deferred, bounced, failed, rejected, and complained messages through [delivery events](delivery-events.md).
- [Match replies](thread-correlation.md) using Cloudflare's returned message ID.

## Receiving

- Deploy the included [Cloudflare Worker](../templates/deploy-to-cloudflare/README.md).
- Retain incoming mail in R2 and retry while Rails is unavailable.
- Verify signed requests and the actual SMTP recipient before storing email.
- Keep original messages and attachments in Rails Action Mailbox.
- Deduplicate repeated deliveries.
- Process email with ordinary Rails mailbox handlers.
- Test incoming email locally with `bin/rails cloudflare:email:dev`.

## Inboxes

- Create named [mailboxes](mailboxes.md), aliases, and optional catch-all addresses.
- Associate mailboxes with application records through `owner_ref`.
- List unread messages, mark them read, archive them, and retain their originals.
- Suspend mailboxes while reserving their addresses.
- Send from an active mailbox through the outbox.
- Mount a [server-rendered management UI](management-engine.md) using your app's login and permissions.
- Use [customer subdomains](../templates/worker/docs/domain-setup.md) with Rails address lookup.

## Storage and providers

SQLite and PostgreSQL are supported. Database multi-tenancy is **off by default**;
you can configure [separate SQLite databases](activerecord-tenanted.md) when needed.

[Mailbox Kit](../mailbox-kit/README.md) works with other Action Mailbox integrations.
Incoming and outgoing mail can use different providers.

## Administration

Use [configuration checks and tasks](reference.md#observability-and-permissions),
[routing diagnostics](routing-diagnostics.md), and ActiveSupport notifications to
monitor your integration. Custom endpoints can reuse the [ingress verification API](custom-ingress.md).
[Routing analytics](routing-deliveries.md) can supply additional delivery evidence
for qualifying messages to verified Routing destinations.

## What the statuses mean

| Status | Meaning |
| --- | --- |
| Send accepted | Cloudflare accepted the send; delivery updates may follow |
| Outbox `partial` | Recipients have different acceptance outcomes; inspect each recipient |
| Delivery event `delivered` | The receiving mail server accepted the message |
| Inbound Rails `delivered` | Your mailbox handler finished processing |
| Inbox read / archived | Your application's inbox state |

Your app supplies users, permissions, sender acceptance rules, and business
processing. The management UI covers administration and message reading; compose
screens, conversations, search, and AI workflows belong in your app.
