# Thread correlation

Email headers help locate a conversation. They do not authorize a person to read it or take an action.

## Prefer provider message IDs

The current Cloudflare sending API reference includes a `message_id`. Store it with your application conversation and the intended recipient. Match inbound `In-Reply-To` and `References` against stored IDs. Both headers can contain multiple IDs; examine them in context instead of assuming the first is the right conversation.

The ActionMailer delivery method updates the Mail object's message ID when Cloudflare returns one. You can also capture it with the `cloudflare_email.send_raw` notification, which includes recipient outcomes, or use the plain client response.

Persist the correlation record durably. API acceptance and application persistence are not one atomic transaction, and older responses may omit the provider ID. Have a fallback path for unmatched replies.

Perform application authorization independently. The email's From header alone is not sufficient proof of identity. Sensitive actions should require the application's established authentication/confirmation flow.

## Legacy SecureMessageId helper

This helper is retained for compatible transports. The September 10 live Cloudflare test replaced custom signed IDs, so use stored provider IDs for Cloudflare sends.

```ruby
secret = Cloudflare::Email::Credentials.fetch(:reply_secret)
signed_id = Cloudflare::Email::SecureMessageId.encode(
  payload: { conversation_id: conversation.id },
  domain: "mail.example.com",
  secret: secret,
)
```

Pass `signed_id` as the outbound mailer's `message_id`. If the transport preserves it and a replying client carries it into `In-Reply-To` or `References`, decode the candidate:

```ruby
payload = Cloudflare::Email::SecureMessageId.decode(candidate_id, secret: secret)
# Look up the conversation, then apply application authorization separately.
```

Use a nonempty, strong dedicated secret in `cloudflare.reply_secret` or `CLOUDFLARE_REPLY_SECRET`. The default maximum age is 30 days; `decode(max_age: seconds)` changes it. Failures raise `SecureMessageId::InvalidToken`.

The signature covers the timestamp and JSON payload. It does not authenticate the email sender, encrypt the payload, make the token single-use, or bind the displayed prefix/domain as an authorization context. Keep payloads small and non-sensitive; encoded IDs over 900 bytes are rejected. Mail clients and providers may impose smaller practical limits.

Current [Cloudflare header documentation](https://developers.cloudflare.com/email-service/reference/headers/) says Message-ID is platform-controlled. The April 2026 project reported a signed-ID round trip, but the [September live test](verification/2026-09-10-live.md) confirmed replacement for both raw-MIME and ActionMailer sends. Provider IDs matched received headers, and replies correlated successfully through those stored IDs. Outgoing replies must also set `In-Reply-To` and `References` from the parent message.

Before relying on this helper, send to a mailbox you control, inspect the delivered raw Message-ID, reply using your supported clients, and verify the returned IDs. No such live send was performed for 0.2.0. If IDs are rewritten, use stored provider-ID correlation instead.
