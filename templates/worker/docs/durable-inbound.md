# Durable inbound delivery

When Rails is down, keep the email at Cloudflare and deliver it when Rails returns.
The bundled Worker uses R2 storage, Queue delivery and scheduled recovery by
default. No enable flag, Rails model, database, or tenancy change is needed.
Missing infrastructure fails visibly; it never silently downgrades to direct delivery.

## Set it up

Create a private R2 bucket and a Queue for each environment:

```sh
npx wrangler r2 bucket create cloudflare-email-inbound-production
npx wrangler queues create cloudflare-email-inbound-production
```

The bundled `wrangler.toml` already configures these resources for each environment.
Customize their names if needed. Configure **all three** pieces: the `INBOUND_EMAIL_STORE` R2
binding, `INBOUND_EMAIL_QUEUE` producer and consumer, and the once-per-minute
scheduled trigger. Keep `RAILS_INGRESS_URL` and `INGRESS_SECRET` configured. Deploy with `npm run deploy -- --env production`.

Use separate buckets, queues and secrets for staging and production. Do not add
an R2 lifecycle rule that expires `cloudflare-email/pending/` objects. Pending
mail has no automatic expiration and can incur storage costs during a long
outage. Do not publish the bucket or expose an unauthenticated recovery endpoint.
Review storage access and retention as you would the Rails email database.
Provision and deploy the infrastructure with Wrangler first; retain that configuration
in your infrastructure repository. Subsequent `cloudflare:email:deploy_worker` Rails
task uploads preserve R2/Queue bindings and check the bucket binding, queue producer
binding, and minute schedule before changing code or secrets. This check does not
validate the bucket lifecycle or queue consumer: verify those in your infrastructure
configuration and live drill. The Ruby task does not provision resources.

## Direct fallback

Set `INBOUND_DELIVERY_MODE = "direct"` in the environment's Wrangler vars only when
you deliberately want a single HTTP handoff. With the Ruby task, pass
`INBOUND_DELIVERY_MODE=direct bin/rails cloudflare:email:deploy_worker`.
Direct mode permanently rejects on HTTP/network failure and cannot buffer an outage.
Keep the existing R2/Queue bindings and cron during fallback: queue and scheduled
recovery continue draining previously retained mail. To return to durable delivery,
remove the Wrangler override or pass `INBOUND_DELIVERY_MODE=durable` to the Ruby task.
Unknown values fail rather than choosing a transport implicitly.

## What happens to a message

1. The Worker validates the envelope and actual MIME size. Invalid or oversized
   mail is permanently rejected.
2. It writes one R2 object containing the exact raw bytes, SMTP envelope, original
   receive time, and optional provider metadata. It waits for the write before
   returning from the Email Worker handler.
3. It queues a small `{ version: 1, key }` pointer. If enqueueing fails, the stored
   object remains discoverable by the scheduled sweep.
4. The consumer signs the original bytes and metadata with a fresh timestamp and
   POSTs to Rails. Only HTTP 2xx permits deleting the pending object; the queue
   message is acknowledged only after that deletion completes.
5. Timeout, connection failure, redirect, 401, 413 and all other non-2xx responses
   retain the object and retry. Fix credentials or size configuration for errors
   that cannot resolve themselves. There is no automatic discard on client errors.

If Rails saved a message but its response was lost, replay sends the same message
identity. Rails ingress deduplicates using the original bytes and envelope (and
provider metadata for v3); changing the signing timestamp does not change that
identity. A failed R2 deletion may also cause replay. A queue pointer to an
already deleted object is a successful no-op and never resends mail. Do not reuse
pending keys, alter saved context, or replace the ingress with an endpoint that
acknowledges before durable ingestion. Retain Rails deduplication records for at
least your maximum recovery horizon; manual restore/replay after Rails incineration
can produce another message. Application processing must tolerate duplicates too.

The scheduled handler scans five pending objects per minute and attempts their
handoff directly. It persists an R2 pagination cursor and advances past failed
objects, wrapping back to the beginning at the end. Poison messages therefore do
not permanently block later pages. This sweep handles both enqueue failure and
exhausted Queue retries without a separate dead-letter queue. During recovery,
Queue consumers provide the primary throughput; scheduled-only recovery takes
at least `ceil(pending_count / 5)` minutes per full pass. Overlapping cron runs
may repeat a page; delivery remains idempotent. Scale and exercise this recovery
rate against your expected backlog before depending on it.

The template buffers MIME to sign it, and the durable path also builds a framed
storage payload. Test messages near your configured size limit with realistic
concurrent traffic against the Worker's memory limit before production rollout.
Lower `MAX_EMAIL_BYTES` in both Worker and Rails if your workload requires it;
lowering it below already retained message sizes leaves those messages pending
until the limit is restored or they are recovered through an authorized process.

## Operate and verify

Enable Worker logs and alerts for the structured
`component: "cloudflare_email_inbound"` events. They include a random storage key
and fixed reason, never raw messages, addresses, secrets or HTTP response bodies.
Alert on `storage_failed`, `enqueue_failed_retained`, repeated `queue_retry_retained`
or `sweep_retry_retained`, Worker exceptions, and growth/age of objects under the
pending prefix. `receivedAt` is inside the private stored frame; R2 object upload
time is also available to infrastructure monitoring. Queue backlog alone is not
sufficient: exhausted pointers may disappear while retained mail remains in R2.
This template emits logs; configure your monitoring service to page the operator.

In staging, stop Rails, send mail, confirm pending R2 objects, restore Rails, then
verify one inbound message and removal of its pending object. Also verify recovery
with the queue consumer disabled or retries exhausted, a lost HTTP response after
Rails saved the message, invalid ingress credentials, and a failed R2 write.
The repository includes unit coverage and a local Worker/Rails integration harness.
Before changing ingress URLs, remember retained messages use the current configured
URL and secret. Drain existing retained mail before repointing a bucket to another
application or disabling the scheduled recovery trigger.

For a custom Worker, import `retainEmail(message, env, { metadata })`,
`consumeRetainedEmails(batch, env)` and `sweepRetainedEmails(env)` from `src/index.js`.
Wire the latter two to your queue and scheduled handlers as in the default export.
For a secondary raw archive, pass `archive: async ({ raw, from, to, key }) => ...`
to `retainEmail`. It runs after the primary R2 commit with the original MIME bytes;
`key` is the pending object identity. Its errors or default 10-second timeout are
logged as `archive_failed_retained` and do not prevent queue delivery. A timed-out
callback is not canceled. Set `archiveTimeoutMs` to an integer from 1 to 120,000
milliseconds to fit your host's runtime budget. Treat bytes as read-only and never parse the private
pending frame to build an archive. The primary R2 write is always mandatory.
Trusted provider metadata is captured once at receipt, never recomputed on replay.
The `relayEmail` archive callback is best effort and does not enable this
durable protocol automatically.

## Guarantee boundary

After a successful R2 write, Rails outages and finite Queue retention do not
discard the stored payload. This is at-least-once handoff, with Rails deduplication;
it is not an absolute guarantee against all loss. R2 write failures, upstream
SMTP acceptance behavior, account suspension, deleted infrastructure, misconfigured
lifecycle rules and manual intervention remain outside that promise. A failed
initial durable write throws and emits an error; it must not be mistaken for
successful storage. Monitor that failure separately.

Cloudflare documents [`setReject`](https://developers.cloudflare.com/email-service/api/route-emails/email-handler/)
as a permanent SMTP rejection. Throwing an Email Worker error is not treated here
as a documented durable SMTP retry contract. Cloudflare Queues has a
[128 KB message limit and finite retention/retries](https://developers.cloudflare.com/queues/platform/limits/),
which is why the queue stores only pointers and R2 retains the message independently.
