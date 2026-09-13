# Durable inbound delivery

When Rails is down, keep the email at Cloudflare and deliver it when Rails returns.
Set `DURABLE_INBOUND_ENABLED = "true"` to replace the bundled Worker's direct HTTP
handoff with R2 storage, Queue delivery and scheduled recovery. This is opt-in;
no Rails model, database, or tenancy setting needs to change.

## Set it up

Create a private R2 bucket and a Queue for each environment:

```sh
npx wrangler r2 bucket create your-production-inbound-email
npx wrangler queues create your-production-inbound-email
```

Uncomment and customize the durable mode configuration at the bottom of
`wrangler.toml`. Configure **all three** pieces: the `INBOUND_EMAIL_STORE` R2
binding, `INBOUND_EMAIL_QUEUE` producer and consumer, and the once-per-minute
scheduled trigger. Keep `RAILS_INGRESS_URL` and `INGRESS_SECRET` configured as
before. Deploy with `npm run deploy -- --env production`.

Use separate buckets, queues and secrets for staging and production. Do not add
an R2 lifecycle rule that expires `cloudflare-email/pending/` objects. Pending
mail has no automatic expiration and can incur storage costs during a long
outage. Do not publish the bucket or expose an unauthenticated recovery endpoint.
Review storage access and retention as you would the Rails email database.
The gem's simple deployment generator does not provision these resources;
retain this customized Wrangler configuration in your infrastructure repository.

## What happens to a message

1. The Worker validates the envelope and actual MIME size. Invalid or oversized
   mail is permanently rejected, as in direct mode.
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
Trusted provider metadata is captured once at receipt, never recomputed on replay.
The existing `relayEmail` archive callback is best effort and does not enable this
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
