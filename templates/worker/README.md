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

The Worker refuses non-HTTPS destinations, URL credentials, and fragments.
HTTP is allowed only for `localhost`, `127.0.0.1`, or `[::1]` local verification.
The Worker and Rails ingress each default to a 25 MiB MIME size limit. Set
`MAX_EMAIL_BYTES` to the same positive integer in both environments to change
that limit. Both check actual body bytes; declared sizes alone are not trusted.
Rails returns HTTP 413 for oversized mail and rejects malformed or stale signing
headers before reading the body. Configure request size/rate limits and read
timeouts at your reverse proxy as well: application limits do not bound earlier
server buffering or the time spent receiving an HTTP request.

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
2. Encodes `{"from": message.from, "to": message.to}` as unpadded base64url JSON,
   then computes `HMAC-SHA256(INGRESS_SECRET, "v2.{unix_timestamp}.{encoded_envelope}.{raw_body}")`.
3. POSTs the raw bytes to `RAILS_INGRESS_URL` with:
   - `Content-Type: message/rfc822`
   - `X-CF-Email-Timestamp: <unix seconds>`
   - `X-CF-Email-Signature: <hex digest>`
   - `X-CF-Email-Signature-Version: 2`
   - `X-CF-Email-Envelope: <encoded envelope>`
4. If Rails responds non-2xx, the network fails, or the request exceeds 15 seconds,
   the Worker calls `message.setReject`. Redirects are refused to prevent sending
   message content and the signature to a different endpoint. The Worker does
   not retry delivery automatically. A timeout can occur after Rails accepted
   the message, so consumers should handle duplicate deliveries.

The Rails controller verifies the signature in constant time and rejects
timestamps outside its 5-minute acceptance window. A signature authenticates the
Worker request, not the original email sender. Captured requests remain valid
inside that window; Rails deduplicates messages through Action Mailbox.

Deploy the Rails gem and this Worker together with ingress paused during the
transition. Rails accepts v2 and v3 signatures and rejects v1/missing versions. It stores authenticated
SMTP metadata separately from MIME; applications read it using
`Cloudflare::Email::Envelope.for(inbound_email)`. Duplicate detection includes the
exact SMTP recipient, preserving separate To/Cc/Bcc deliveries. The format accepts
ASCII dot-atom addresses up to 254 bytes (local part up to 64 bytes), plus an empty
sender for bounce messages. Other address forms are rejected before forwarding.

## Reuse an existing Worker

Keep your existing archiving, sender checks, and fallback policy. Copy this
template's `src/index.js` into your Worker project and import either helper.
`forwardEmail(message, env)` uses the same bounded reading, URL checks, timeout,
and rejection policy as the bundled Worker. Optional metadata selects v3 signing:

```js
import { forwardEmail } from "./cloudflare-ingress.js";

export default {
  async email(message, env) {
    // Supplied by your integration after validating its trusted provider context.
    // This is your adapter function, not a Cloudflare EmailMessage API.
    const providerData = await yourValidatedProviderContext(message, env);
    return forwardEmail(message, env, {
      metadata: { source: "your-provider", data: providerData },
    });
  },
};
```

The bundled Worker does not collect provider authentication results. Never treat
`Authentication-Results`, `Received-SPF`, or other sender-supplied MIME headers as
trusted provider context. Signing metadata authenticates your Worker's assertion;
it does not prove DMARC passed or authorize the original sender. Your application
still owns sender policy, organization resolution, review, and document processing.

If your Worker already owns transport and error handling, use the header builder:

```js
import { signedEmailHeaders } from "./cloudflare-ingress.js";

const headers = await signedEmailHeaders({
  secret: env.INGRESS_SECRET,
  raw, // Original Uint8Array, obtained using your own bounded reader.
  from: message.from,
  to: message.to,
  metadata: { source: "your-provider", data: providerData },
});
// Send these headers with exactly `raw`, using your existing transport.
```

The builder performs no network calls. You own destination validation, body size
limits, timeouts, redirects, retries, and response handling. An optional `timestamp`
in Unix seconds supports deterministic testing; production normally uses the
default current time. Omitting `metadata` produces unchanged v2 headers. Invalid
metadata throws from the builder; the forwarding helper rejects instead of
silently falling back to v2.

Metadata must contain exactly `source` and `data`. Source matches
`[a-z][a-z0-9_.-]{0,127}`; data is a JSON object, with only JSON values and at most
eight container levels including the outer metadata object. The UTF8 JSON is
encoded as unpadded base64url, limited to 16,384 encoded characters, and sent as
`X-CF-Email-Metadata`. Version 3 signs the exact bytes:

```text
HMAC-SHA256(secret, "v3.{timestamp}.{encoded_envelope}.{encoded_metadata}.{raw_body}")
```

Neither the MIME nor its headers are rewritten. Upgrade Rails to a version that
supports v3 before enabling metadata in a custom Worker. Keep sensitive provider
data out of metadata unless your application's retention and access policies
permit storing it with email records.

## Reuse the transport in an existing Worker

`relayEmail` provides bounded reading, an optional archive, backend selection and
one HTTP delivery attempt. Your Worker decides how a result maps to SMTP
rejection, retry, fallback forwarding or logging. It does not call `setReject`
or `forward` and does not extract or interpret sender authentication evidence.
The existing default export and `forwardEmail` keep their existing behavior.

```js
import { relayEmail, archiveEmail, signedEmailHeaders } from "./cloudflare-ingress.js";

export default {
  async email(message, env) {
    const outcome = await relayEmail(message, {
      maxEmailBytes: 25 * 1024 * 1024,
      timeoutMs: 15_000,
      archiveTimeoutMs: 10_000,
      // Omit archive when no bucket is configured. Key policy belongs to your app.
      archive: env.EMAIL_ARCHIVE ? (args) => archiveEmail({
        ...args, bucket: env.EMAIL_ARCHIVE,
        key: `email/${crypto.randomUUID()}.eml`,
      }) : undefined,
      accepts: async ({ to }) => to.endsWith("@inbound.example.com"),
      // Select only host-configured backends; never use a URL from an email header.
      resolveBackend: async ({ from, to }) => ({
        url: env.RAILS_INGRESS_URL, secret: env.INGRESS_SECRET,
      }),
      headers: ({ raw, from, to, backend }) => signedEmailHeaders({
        raw, from, to, secret: backend.secret,
      }),
    });
    // Example host policy: permanent rejection only for invalid/unaccepted mail;
    // throw for delivery failures so Cloudflare can apply its retry behavior.
    if (outcome.status === "rejected") message.setReject("email not accepted");
    if (outcome.status === "failed") throw new Error("email relay unavailable");
  },
};
```

The relay reads the original stream once, enforcing the actual byte limit even
when `rawSize` underreports it. It archives before checking `accepts` and before
resolving the backend, so an archive can retain mail rejected by host policy.
Invalid envelopes, unreadable streams and oversized messages are not archived.
An archive exception or timeout does not prevent delivery: the result has
`archiveFailed: true`. The archive deadline defaults to 10 seconds and can be
changed with `archiveTimeoutMs`. It stops waiting but cannot cancel an R2 write:
a timed-out archive may still finish later if the runtime remains alive. Monitor
that flag if the archive is your outage recovery mechanism. Other callback
implementations must finish within the Worker's runtime limits; the `timeoutMs`
option applies to the HTTP request only.

`accepts` must return exactly `true` to accept. `resolveBackend` returns an object
with `url` and any additional host configuration needed by `headers`. Backend
URLs must use HTTPS, or HTTP on localhost, `127.0.0.1` or `[::1]`; embedded
credentials and fragments are rejected. Generic relay envelope checks enforce
bounded strings without control characters, leaving address shape to the host.
`signedEmailHeaders` retains the gem ingress's stricter ASCII address validation.

The `headers` callback receives `{ raw, from, to, backend, archive }`, where
`archive` is the archive callback's return value, or undefined on omission or
failure. It can return a header object or `Headers`, including Basic credentials
for an existing custom endpoint. The relay sends exactly `raw`, follows no
redirects, cancels response bodies without reading them, and never includes
backend response content or callback exception text in results. Callbacks are
trusted host code: preserve the supplied bytes and keep secrets out of logs.
Do not put an archive key or other per-attempt value into signed provider metadata;
doing so changes the persisted message identity on retries.

Every result has `status`, `reason` and `archiveFailed`. HTTP responses also add
`httpStatus`:

| Status | Reasons |
| --- | --- |
| `delivered` | `delivered` (HTTP 2xx) |
| `rejected` | `invalid_envelope`, `too_large`, `not_accepted` |
| `failed` | `unreadable`, `invalid_options`, `acceptance_failed`, `backend_failed`, `invalid_backend`, `headers_failed`, `timeout`, `fetch_failed`, `http_status` |

All non-2xx responses, including redirects and permanent client errors, return
`failed`/`http_status`; your host chooses which are permanent, retryable or eligible
for fallback. The relay never retries on its own.

`archiveEmail({ bucket, key, raw, from, to })` writes raw RFC822 bytes to an R2
binding and returns `{ key }`. Keys must be nonempty, at most 1,024 UTF8 bytes and
contain no ASCII control characters. It stores `message/rfc822` content type and
ASCII-safe `from`, `to` and `size` custom metadata; non-ASCII envelope characters
become `?` in this display metadata only. Retention, unique keys, archive browsing
and recovery authorization belong to the host. Rails email persistence starts
after delivery and does not replace this optional outage archive.

## Validate changes

```sh
npm ci
npm test
npm run check
npm audit
```

Tooling dependencies are development-only; the deployed Worker imports no npm
packages. `check` bundles a development deployment locally without publishing.
