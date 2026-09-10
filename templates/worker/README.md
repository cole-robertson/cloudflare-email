# cloudflare-email-ingress

A Cloudflare Email Worker that forwards inbound mail to a Rails ActionMailbox
ingress shipped with the [`cloudflare-email`](https://github.com/cole-robertson/cloudflare-email)
gem.

## Deploy

```sh
npm ci
npx wrangler secret put INGRESS_SECRET --env production
npx wrangler secret put RAILS_INGRESS_URL --env production
npm run deploy -- --env production
```

Use Node 22 (at least 22.12), 24, or 26+. `INGRESS_SECRET` must match Rails' ingress secret;
`RAILS_INGRESS_URL` is your public HTTPS endpoint, for example
`https://your-app.com/rails/action_mailbox/cloudflare/inbound_emails`.
The deploy and dev scripts require an explicit `development`, `staging`, or
`production` environment. Each has its own Worker and secrets; set both secrets
for each environment you use. For local development, run
`npm run dev -- --env development`, with secrets in `.dev.vars.development`.
Never put secrets into `wrangler.toml` or version control.

Then in the Cloudflare dashboard:

1. **Email Routing → Routes**
2. Add a route for the address you want to receive on (e.g. `support@yourdomain.com`)
3. Action: **Send to a Worker** → `cloudflare-email-ingress-production`

Select the corresponding suffix when deploying another environment. Configure
Email Routing DNS for the exact domain/subdomain first. Deploying this Worker
does not change DNS or create routing rules.

## How it works

For each inbound message, the Worker:

1. Reads the raw RFC822 bytes from `message.raw`.
2. Computes `HMAC-SHA256(INGRESS_SECRET, "{unix_timestamp}.{raw_body}")`.
3. POSTs the raw bytes to `RAILS_INGRESS_URL` with:
   - `Content-Type: message/rfc822`
   - `X-CF-Email-Timestamp: <unix seconds>`
   - `X-CF-Email-Signature: <hex digest>`
4. If Rails responds non-2xx, the network fails, or the request exceeds 15 seconds,
   the Worker calls `message.setReject`. Redirects are refused to prevent sending
   message content and the signature to a different endpoint. The Worker does
   not retry delivery automatically. A timeout can occur after Rails accepted
   the message, so consumers should handle duplicate deliveries.

The Rails controller verifies the signature in constant time and rejects
timestamps outside its 5-minute acceptance window. A signature authenticates the
Worker request, not the original email sender. Captured requests remain valid
inside that window; Rails deduplicates messages through Action Mailbox.

## Validate changes

```sh
npm ci
npm test
npm run check
npm audit
```

Tooling dependencies are development-only; the deployed Worker imports no npm
packages. `check` bundles a development deployment locally without publishing.
