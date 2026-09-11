# Thread correlation

Store the provider's returned `message_id` with the intended recipient and your
application conversation. The ActionMailer delivery method updates the Mail
object's message ID when Cloudflare returns one. Plain Ruby callers can read
`response.message_id`.

Normalize stored IDs and parsed `In-Reply-To` / `References` values with
`Cloudflare::Email::MessageId.normalize(value)`. This removes surrounding whitespace
and one complete angle-bracket pair; it preserves case. Parse multiple-ID headers
with your mail parser first. Match `In-Reply-To` first, then `References` from most
recent to oldest, scoped to the authenticated recipient's mailbox.

Outgoing replies should set `In-Reply-To` and `References` using the parent
message's ID. Keep unmatched replies available for application handling when an
ID is missing or unknown. Send acceptance and saving the returned ID are not one
atomic transaction.

The old `SecureMessageId` helper was removed before the 0.2 release. Cloudflare
controls Message-ID and our [live test](verification/2026-09-10-live.md) confirmed
replacement of custom IDs for both raw MIME and ActionMailer sends. The provider's
returned IDs matched received headers and supported reply correlation.

Email headers locate a conversation; they do not authorize access to it. Scope
lookups by the trusted SMTP recipient obtained through `Envelope.for(inbound)`.
The SMTP envelope sender and MIME From header do not authenticate a person.
Sensitive actions require your application's authentication and approval policy.
