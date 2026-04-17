# cloudflare-email-ingress

A Cloudflare Email Worker that forwards inbound mail to a Rails ActionMailbox
ingress shipped with the [`cloudflare-email`](https://github.com/cole/cloudflare-email)
gem.

## Deploy

```sh
npm install
wrangler secret put INGRESS_SECRET     # same value as cloudflare.ingress_secret in Rails credentials
wrangler secret put RAILS_INGRESS_URL  # e.g. https://your-app.com/rails/action_mailbox/cloudflare/inbound_emails
wrangler deploy
```

Then in the Cloudflare dashboard:

1. **Email Routing → Routes**
2. Add a route for the address you want to receive on (e.g. `support@yourdomain.com`)
3. Action: **Send to a Worker** → `cloudflare-email-ingress`

## How it works

For each inbound message, the Worker:

1. Reads the raw RFC822 bytes from `message.raw`.
2. Computes `HMAC-SHA256(INGRESS_SECRET, "{unix_timestamp}.{raw_body}")`.
3. POSTs the raw bytes to `RAILS_INGRESS_URL` with:
   - `Content-Type: message/rfc822`
   - `X-CF-Email-Timestamp: <unix seconds>`
   - `X-CF-Email-Signature: <hex digest>`
4. If the Rails app responds non-2xx, the Worker calls `message.setReject` so
   Cloudflare returns a delivery failure to the sender (the message is not
   silently dropped).

The Rails controller verifies the signature in constant time and rejects
timestamps older than 5 minutes (replay protection).
