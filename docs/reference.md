# Ruby and Rails reference

For a first setup, follow the [Rails quickstart](getting-started.md).

## Plain Ruby

```ruby
require "cloudflare-email"

client = Cloudflare::Email::Client.new(
  account_id: ENV.fetch("CLOUDFLARE_ACCOUNT_ID"),
  api_token: ENV.fetch("CLOUDFLARE_API_TOKEN"),
)

response = client.send(
  from: { address: "hello@mail.example.com", name: "Example" },
  to: "you@example.net",
  subject: "Hello",
  text: "Plain body",
  html: "<p>HTML body</p>",
  reply_to: "support@in.example.com",
)
response.message_id             # Provider ID when returned
response.delivered              # Immediately delivered recipients
response.queued                 # Recipients queued for later delivery
response.permanent_bounces      # Recipients that permanently bounced
response.suppressed_recipients  # Recipients dropped by suppression policy
```

`to` may be omitted for cc-only or bcc-only mail. Addresses accept strings or `{ address:, name: }` hashes. Attachments use Cloudflare's `content` (base64), `filename`, `type`, `disposition`, and optional `content_id` fields. For full MIME control, use `client.send_raw(from:, recipients:, mime_message:)`.

An HTTP success does not mean every recipient received the message. Inspect the recipient outcome arrays and use [delivery events](delivery-events.md) for later results. 

Cloudflare currently limits ordinary sends to 50 recipients and 5 MiB including attachments; verified destination addresses have a 25 MiB allowance. These limits are enforced by Cloudflare. See [limits](https://developers.cloudflare.com/email-service/platform/limits/) and the [header allowlist](https://developers.cloudflare.com/email-service/reference/headers/).

## Receive through ActionMailbox

Cloudflare Email Routing invokes an Email Worker. The bundled Worker forwards unchanged raw MIME to Rails with a versioned HMAC-SHA256 signature covering the timestamp, SMTP envelope, and body. Rails verifies the signature and a five-minute timestamp window before storing the message in ActionMailbox.

```sh
bin/rails generate cloudflare:email:install
```

The interactive installer offers ActionMailbox installation/migrations and a default `MainMailbox`, copies the Worker, and configures ingress in development and production. Add `--all-envs` to include test; configure custom staging environments explicitly. Send-only apps do not need ActionMailbox.

Add the generated ingress secret and an optional management token:

```yaml
cloudflare:
  account_id: your-account-id
  api_token: your-runtime-send-token
  management_token: your-deployment-token
  ingress_secret: the-generated-random-secret
```

Equivalent environment names are `CLOUDFLARE_MANAGEMENT_TOKEN` and `CLOUDFLARE_INGRESS_SECRET`. Keep management credentials in the deployment environment rather than the running application. Credentials stored in the application's Rails credentials are accessible to that application; this gem is not a secret-isolation boundary.

1. Add the receiving subdomain, for example `in.example.com`, in **Email Routing → apex domain → Settings → Subdomains**. This is a separate onboarding step from sending.
2. Deploy the environment's Worker and create its route:

First create the private R2 bucket and Queue, then deploy the generated Wrangler
configuration using the [durable setup guide](../templates/worker/docs/durable-inbound.md).
The Ruby task below updates that provisioned Worker while preserving its bindings.
It refuses a missing bucket/queue binding or recovery schedule before changing code.

```sh
RAILS_ENV=production bin/rails cloudflare:email:deploy_worker URL=https://app.example.com/rails/action_mailbox/cloudflare/inbound_emails
RAILS_ENV=production bin/rails cloudflare:email:provision_route ADDRESS=support@in.example.com
```

Subdomain provisioning checks configured DNS before creating a rule. It never enables the parent apex on behalf of a subdomain. A missing setup or permission fails with instructions. DNS records alone do not prove propagation or live routing; send a real test afterward.

For a zone apex, provisioning may enable Email Routing and its DNS records. Only use this when Cloudflare should handle mail for that apex. `provision_catchall DOMAIN=example.com` changes the **zone-wide** catch-all; a subdomain that resolves to a parent zone is rejected. See [subdomain onboarding](https://developers.cloudflare.com/email-service/configuration/subdomains/).

Replace the scaffolded mailbox's `process` with your application logic. For tenant or mailbox selection, use the authenticated SMTP recipient rather than the sender-controlled MIME `To`/`Cc` headers:

```ruby
class ApplicationMailbox < ActionMailbox::Base
  routing ->(inbound) { Cloudflare::Email::Envelope.for(inbound)&.fetch("to")&.match?(/\Asupport@/i) } => :support
end
```

`Cloudflare::Email::Envelope.for(inbound_email)` returns a string-keyed `{"from" => "sender@example.com", "to" => "support@example.com"}` hash, or `nil` when the record has no authenticated envelope (for example, another ingress). The metadata is stored on the raw-email blob before routing jobs enqueue. It does not modify the MIME source. Envelope sender information records the SMTP reverse path; it does not authenticate the human sender. An empty `from` is valid for bounces.

The bundled Worker uses v2 signatures by default; missing or v1 signatures are rejected. The custom-ingress API also supports opt-in v3 signatures carrying authenticated Worker metadata. See [custom ingestion](custom-ingress.md) for signed Worker metadata. Both envelope versions require ASCII dot-atom addresses, at most 254 bytes with a 64-byte local part. Quoted local parts, address literals, and internationalized addresses are not supported by this envelope format.

Successful ingress storage returns HTTP 200; duplicate storage returns 200 too. The timestamp window limits request age, but is not a one-time replay ledger. Version 2 deduplication includes the exact SMTP recipient, so identical MIME delivered to separate To/Cc/Bcc recipients creates separate inbound records while a retry for the same recipient creates none.

The Worker has a 15-second Rails request timeout and rejects redirects. Its default [durable inbound path](../templates/worker/README.md#durable-inbound-delivery) saves messages in R2 before acceptance, then retries Rails handoffs through Queues and scheduled recovery. Provision the resources before deploying. `INBOUND_DELIVERY_MODE=direct` selects the single-attempt fallback, which can reject mail during an outage; existing retained mail keeps recovering. Rails storage acceptance does not guarantee later mailbox-job success. Monitor Rails jobs and Cloudflare Worker logs.

### Local development and deployment

For a simple development tunnel, use the explicit direct fallback. Start Rails, then:

```sh
INBOUND_DELIVERY_MODE=direct bin/rails cloudflare:email:deploy_worker
bin/rails cloudflare:email:dev
```

The dev task requires `cloudflared`, refuses environments other than development, and updates the existing development Worker's URL to a temporary tunnel. It forces a dedicated origin Host; development middleware permits only POSTs to the email ingress on that Host. The task checks that the guard is running before opening the tunnel. Configure a separate development receiving address and route. Stopping the tunnel leaves that URL in the development Worker until the next update. A Worker deployed without a URL rejects mail until the tunnel sets it.

For a custom installer `--worker-dir`, pass `SCRIPT=custom-directory/src/index.js` to the Ruby `deploy_worker` task. The installer prints the corresponding command.

Ruby deployment and Wrangler use matching names: `cloudflare-email-ingress-development`, `-staging`, and `-production`. Initial durable infrastructure deployment uses Wrangler and requires Node 22.12+ (or a supported newer version):

```sh
cd cloudflare-worker
npm ci
npx wrangler secret put INGRESS_SECRET --env production
npx wrangler secret put RAILS_INGRESS_URL --env production
npm run deploy -- --env production
```

See the [Worker README](../templates/worker/README.md).

Rotate the shared ingress secret in Rails and the corresponding Worker during a coordinated deployment. This version has no overlapping-key rotation window; requests can fail while secrets differ.

## Retry and configuration

`Client.new` options are also accepted by `config.action_mailer.cloudflare_settings`:

| Option | Default |
|---|---|
| `account_id`, `api_token` | Required |
| `base_url` | `https://api.cloudflare.com/client/v4` |
| `timeout` | 30 seconds for open/read/write |
| `total_timeout` | Defaults to `timeout`; bounds one complete HTTP attempt, including headers and streamed body |
| `max_response_bytes` | 1 MiB for `Client`; 32 MiB for `EventConsumer` queue batches |
| `retries` | 3 additional attempts |
| `initial_backoff` | 0.5 seconds, doubling |
| `max_retry_after` | 60 seconds |
| `retry_ambiguous` | `false` |
| `logger` | `nil`, optional `warn` logger |

By default, only 429 responses and pre-send connection failures retry. Numeric and HTTP-date `Retry-After` values are honored up to the cap. Read/write timeouts, connection resets, and 5xx responses may occur after acceptance; they raise without automatically resending. Setting `retry_ambiguous: true` restores retries for those failures and can send duplicates.

Responses are streamed with a byte limit, including decompressed content and
error responses. A total deadline or response-size failure after transmission
does not prove a send failed: the outbox preserves the ambiguous claim and blocks
automatic resend. Net::HTTP's implicit retries are disabled. Explicit retries
and backoff can make a logical call longer than `total_timeout`; queue handlers,
database transactions and a complete polling run have separate runtime budgets.
An uncertain queue acknowledgement permits receipt replay, never email resending.

No idempotency key is sent. Reusing Message-ID does not guarantee deduplication or exactly-once delivery. Account for ActiveJob's retry policy too: retrying the whole mailer job can resend even when this client's retries are disabled.

Errors inherit from `Cloudflare::Email::Error`: `ConfigurationError`, `AuthenticationError`, `ValidationError`, `RateLimitError`, `ServerError`, and `NetworkError`. API errors expose `status` and parsed `response`.

## Observability and permissions

Notifications: `cloudflare_email.send` / `send_raw` include `account_id`, `path`, `status`, `message_id`, and all four recipient outcome arrays. `cloudflare_email.ingress` includes `bytes`, `result` (`ok`, `duplicate`, `bad_signature`, `stale`, `too_large`), and the stored `message_id` when available. `cloudflare_email.delivery_event` wraps handler execution with `event_id`, `message_id`, and lifecycle `status`; it does not report queue acknowledgement completion. Instrumentation errors include ActiveSupport's exception metadata.

| Task | Purpose / credentials |
|---|---|
| `doctor` | Read diagnostics with runtime token; limited read permissions are reported |
| `send_test FROM=... TO=...` | Send a real message using runtime send permission |
| `deploy_worker URL=https://...` | Management token: Workers Scripts Edit |
| `provision_route ADDRESS=...` | Management token: Zone Read, Email Routing Rules Edit; DNS Read for subdomain checks; routing-settings write permission for apex enablement |
| `provision_catchall DOMAIN=...` | Same routing management permissions; changes the zone-wide catch-all |
| `dev` | Management token: Workers Scripts Edit; development only |
| `consume_events` | Separate Queues Read/Write token, queue ID, configured handler |
| `deliver OPERATION_KEY=...` | Dispatch a saved outbox operation using sending credentials |
| `replay_events [MESSAGE_ID=...]` | Replay durable receipts for the configured account |
| `pending_deliveries` | List prepared or uncertain outbox operations for operator review |

The optional Rails adapter emits `cloudflare_email.outbox_prepare`,
`cloudflare_email.outbox_send`, and `cloudflare_email.outbox_reconcile` notifications
with operation identity and resulting state. These do not contain MIME or API
tokens. A notification is method instrumentation; an enclosing application
transaction may still roll back. Inspect the durable ledger for authoritative state.

Management tasks fall back to the runtime token if `management_token` is unset. Restrict scopes and accounts to the operations you need. Event consumers use a separate `queues_token` and do not fall back to a send token.

## SMTP alternative

Cloudflare also supports authenticated SMTP. Existing Rails SMTP applications can use it without this gem's delivery method:

```ruby
config.action_mailer.delivery_method = :smtp
config.action_mailer.smtp_settings = {
  address: "smtp.mx.cloudflare.net",
  port: 465,
  ssl: true,
  authentication: :plain,
  user_name: "api_token",
  password: ENV.fetch("CLOUDFLARE_SMTP_TOKEN"),
}
```

Cloudflare documents Email Sending Edit permission for SMTP, implicit TLS on port 465, and no outbound STARTTLS on 587. See [SMTP documentation](https://developers.cloudflare.com/email-service/api/send-emails/smtp/). Remove the generated `:cloudflare` initializer override if switching to SMTP.
