# Upgrade from 0.1.0 to 0.2.0

0.2.0 adds delivery events and changes defaults where 0.1.0 could resend mail or misconfigure routing. It is prepared as a release candidate; publishing the gem is a separate step.

## Application changes

1. **Ruby:** the declared minimum is now 3.2, matching the oldest compatibility job. Prefer a maintained Ruby version. CI also covers Ruby 4.0 with Rails 8.1.
   Base64 is now an explicit runtime dependency so isolated Ruby 3.4/4 applications can load the gem without Rails' transitive dependencies.
2. **Initializer:** replace direct credential lookups with `Cloudflare::Email::Credentials.account_id` and `.api_token`. This fixes the documented environment fallback for existing apps; upgrading the gem does not rewrite an initializer.
3. **Send retries:** 429 and pre-send connection failures retry by default. Ambiguous failures (read/write timeouts, resets, and 5xx) no longer resend automatically. Set `retry_ambiguous: true` only if duplicate sends are an acceptable tradeoff. Review ActiveJob retries separately.
4. **Receiving environments:** the installer now configures development and production ingress. Existing applications should add `config.action_mailbox.ingress = :cloudflare` where needed. `--all-envs` also includes test; staging is explicit.
5. **Dev tunnel:** `cloudflare:email:dev` refuses staging/production. Use separate routed addresses and Workers for development.
6. **Test sends:** both `FROM=` and `TO=` are required. The unsupported account-domain autodetection endpoint was removed.
7. **JSON/Rails:** the gem's development bundle pins JSON below 3 because current tested Rails releases call the pre-3.0 positional-options API. If an existing Rails application's bundle selects JSON 3 and fails in `ActiveSupport::JSON.decode`, constrain `gem "json", "< 3"` in that application's Gemfile until its Rails version supports JSON 3. The gem does not impose this Rails-specific constraint on plain Ruby consumers.

## Worker and routing migration

Copy/review the updated Worker files from this gem; the generator does not silently replace your deployed Worker.

Upgrade the Rails gem **before** deploying the v2 Worker. Its HMAC now covers the
SMTP envelope as well as unchanged MIME. Rails stores that authenticated metadata
before enqueueing routing jobs. `Cloudflare::Email::Envelope.for(inbound_email)`
returns a string-keyed `from`/`to` hash, or `nil` for legacy requests. Legacy
signatures remain accepted, but HTTP/MIME envelope headers are never trusted for
those requests. Route tenant mailboxes using the trusted SMTP recipient instead
of MIME `To`/`Cc`; decide explicitly how the application handles missing metadata.
Identical MIME for separate SMTP recipients is stored separately; retries for the
same exact recipient remain duplicates. This includes Bcc deliveries without a
visible recipient header. The envelope format supports ASCII dot-atom addresses
up to 254 bytes, with a 64-byte local part, and an empty SMTP sender for bounces.

- Node tooling uses a tracked package-lock, `npm ci`, Node 22.12+ (or supported newer), Wrangler 4.131+, and Vitest 5.
- Include `scripts/wrangler.mjs`, `package-lock.json`, and the updated `wrangler.toml`.
- Wrangler deploy/dev scripts require `--env development|staging|production`.
- Both deployment paths now target `cloudflare-email-ingress-<environment>`. Existing unsuffixed Workers are not deleted. Set both secrets on the new Worker, deploy, verify, then deliberately update the corresponding route.
- The forwarding Worker now times out after 15 seconds and refuses redirects. Ensure the Rails URL is the final HTTPS endpoint. Both deployment paths use compatibility date 2026-09-10.
- For an installer `--worker-dir` other than the default, pass `SCRIPT=your-directory/src/index.js` to the Ruby deploy task.
- The development tunnel sets the origin Host to localhost, preserving Rails' normal development host authorization.
- Subdomain routes require separately onboarded routing DNS and DNS Read access for preflight. The provisioner no longer enables the parent apex to make a subdomain work.
- Catch-all provisioning is explicitly zone-wide. A request for a subdomain that resolves to a parent zone fails rather than replacing the parent's catch-all.
- Apex enablement uses the current routing DNS API. Permission/setup errors stop provisioning; they are no longer ignored.
- Rule lookup now paginates and only updates matching single literal-address rules.

Do not enable Cloudflare routing at the apex of a domain whose mail belongs to Workspace/Outlook. Follow Cloudflare's current subdomain onboarding flow.

## Delivery state and thread correlation

Responses and notifications expose `message_id` when present and `suppressed_recipients`. API success can include permanent bounces or suppression. Monitor recipient outcomes.

Add a dedicated Queue, Email Sending event subscription, and HTTP pull consumer to use [delivery events](delivery-events.md). Existing applications are not subscribed or polled automatically. Provide an idempotent handler and configure retries/dead-letter handling.

The old README's signed-reply identity and exactly-once claims were too strong. Signed Message-IDs prove payload integrity, not sender identity, and a repeated Message-ID is not a send idempotency key. Review [thread correlation](thread-correlation.md) before retaining that feature. Live testing confirmed Cloudflare replaces custom IDs: store provider IDs and include parent IDs in outgoing reply headers.

## Verification before publishing/deploying

Local automated coverage includes fresh Rails installation/migrations/mailbox execution, task orchestration, packaged installation, duplicate deliveries, mocked sending/routing/event APIs, Worker unit tests, dry-run builds, and actual local workerd-to-Rails forwarding. The runtime test caught and fixed unsupported `redirect: "error"`; the Worker now uses `manual` and rejects 3xx responses. The API tests exercise documented contracts; they do not prove a live account is configured. See the [verification report](verification/2026-09-10.md).

In an account and mailboxes you control, verify these before production rollout:

- Sending-domain DNS and outbound MIME/attachments/cc/bcc behavior.
- Subdomain receiving routes and each environment's deployed Worker.
- Ingress response handling and application mailbox jobs.
- Queue subscription, event encoding, handler persistence, and acknowledgements.
- Actual delivered Message-ID and reply threading if using the legacy signed-ID helper.

No live account actions, messages, or releases were performed as part of the automated update.
