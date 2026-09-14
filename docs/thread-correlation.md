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

Cloudflare controls the outgoing Message-ID. Store the returned provider ID
instead of relying on a custom ID supplied before sending.

Email headers locate a conversation; they do not authorize access to it. Scope
lookups by the trusted SMTP recipient obtained through `Envelope.for(inbound)`.
The SMTP envelope sender and MIME From header do not authenticate a person.
Sensitive actions require your application's authentication and approval policy.
