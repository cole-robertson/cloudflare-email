# Durable inbound and Routing delivery verification

This change brings the verified Routing-delivery correlation from Rebulk into an
optional gem API and adds inbound storage/recovery for Rails outages. All tests
below use synthetic messages and disposable local storage. This report does not
claim the new Worker configuration is deployed in Rebulk production.

## Boundaries verified

- Shared sending/queue HTTP requests stream bounded responses, including gzip
  expansion, and enforce a total network deadline. Real socket tests cover
  slow streams, socket cleanup, oversized replies and uncertain queue ACKs.
  No ambiguous failure automatically resends an accepted email.
- Authenticated Routing analytics validates account/zone, provider ID, sender,
  request window and a single saved envelope recipient. Dedicated encrypted
  receipts preserve provider evidence and support idempotent projection.
- Inbound R2 persistence finishes before successful Email Worker return. Queue
  messages contain only a storage pointer. Failed enqueue, Rails errors, lost
  responses, failed deletion and exhausted retries retain the pending payload.
  Scheduled pagination advances over poison messages and retries retained mail.
- A real local workerd instance uses R2 and Queues against Rails with SQLite and
  disk-backed Active Storage. With queue retries disabled, Rails 503 leaves mail
  in R2; invoking the scheduled handler after recovery persists one message and
  removes the pending object. Returning 503 after Rails commits also replays to
  one record. MIME and binary attachments remain byte-identical.
- Missing Message-ID fallback remains stable when Rails hostnames change. Valid
  Message-IDs and raw MIME are preserved. Pre-upgrade fallback IDs require care
  when replaying historical archive records.
- Local workerd capacity checks pass for one 25 MiB message and two concurrent
  25 MiB receipts, followed by concurrent handoffs. The receiver verifies exact
  SHA256 and HMAC values, and R2 pending objects clear after acknowledgement.
  Local workerd does not certify production memory-limit enforcement.

## Reproduce

Use Ruby 3.4 and Node 22 or another supported version:

```sh
BUNDLE_GEMFILE=gemfiles/local_ingress.gemfile bundle install
npm ci --prefix templates/worker
BUNDLE_GEMFILE=gemfiles/local_ingress.gemfile bundle exec rake test
npm test --prefix templates/worker
npm run check --prefix templates/worker
node script/verify_durable_capacity.mjs
BUNDLE_GEMFILE=gemfiles/local_ingress.gemfile bundle exec ruby script/verify_local_ingress.rb
BUNDLE_GEMFILE=gemfiles/local_ingress.gemfile bundle exec ruby script/verify_package.rb
```

The local runtime harness invokes the real scheduled handler through a temporary
test-only endpoint. It does not test Cloudflare's production cron scheduler or
SMTP delivery behavior. No test endpoint is shipped in the Worker.

## Before production enablement

Provision a private R2 bucket, queue and schedule per environment, and keep
pending objects free of lifecycle expiration. Deploy the updated Rails ingress
first. Verify maximum message size and recovery throughput with expected traffic,
then perform a staging outage drill through the actual Cloudflare email route.
Monitor storage errors and pending object age as well as queue backlog. Keep
Rails deduplication records throughout the recovery horizon and monitor mailbox
routing jobs after durable ingestion.

Routing tracking is separately opt-in and needs encryption keys, its migration,
a restricted analytics read credential, and host scheduling. Cross-database
applications must retain their durable business projection boundary and enforce
provider-ID uniqueness across tenant databases. Missing delivery evidence stays
unresolved; it never authorizes another send.

R2 storage and retry protect mail after a successful storage commit. They cannot
promise absolute losslessness during upstream storage failure, deletion,
misconfiguration or account suspension. See the [operating guide](../../templates/worker/docs/durable-inbound.md).
