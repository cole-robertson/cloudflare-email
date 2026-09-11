# When email does not behave as expected

Start by identifying which step failed: sending, incoming storage, mailbox
processing, or delivery tracking. Those are separate pieces. Use test addresses
you control, and avoid pasting tokens, raw MIME or private provider responses
into public logs or issues.

## Sending

| What you see | What to check next |
| --- | --- |
| New generator or API is missing | Check `Gemfile.lock`. The new features require the [0.2 commit](getting-started.md#install-the-current-code); published 0.1.0 lacks them. |
| Credentials appear to be ignored | Nonempty Rails credentials override environment variables. Check the Rails environment and restart the app after changes. |
| Authentication or domain error | Run `bin/rails cloudflare:email:doctor`; check account ID, token permissions and sending-domain verification. |
| `doctor` reports limited read access | A send token may lack diagnostic read permissions. Review the specific result; diagnostics alone cannot prove whether sending works. |
| API accepted the message but nothing arrives | Inspect queued, bounced and suppressed recipient outcomes, then delivery events and the destination's spam folder. Acceptance is not final delivery. |
| `deliver_later` does nothing | Check your job backend, running workers and failed jobs. For the outbox's `SendJob`, make sure a worker processes `mailers`. |
| Timeout or server error | Cloudflare might have accepted the message before the error. Investigate before resending. The outbox preserves this uncertainty. |
| Some recipients received it | Inspect each recipient; do not resend the entire partial batch. See [outbox recovery](outbox.md#reconcile-uncertainty). |

To perform a deliberate real-send check:

```sh
FROM=hello@mail.example.com TO=you@example.net bin/rails cloudflare:email:send_test
```

## Incoming email

| What you see | What to check next |
| --- | --- |
| Address receives nothing | Verify receiving-subdomain onboarding and the address route's Worker. Sending-domain verification is separate. |
| Route provisioning refuses a subdomain | Complete Email Routing subdomain setup and DNS preflight first. Do not enable or replace apex routing just to bypass the error. |
| Worker reports 401 from Rails | Check matching ingress secrets and that Rails and Worker both use the v2 code. Upgrade both together. |
| Worker reports 408 | Check clock accuracy and the five-minute signing window. |
| Worker reports 413 or rejects size | Raw MIME exceeds the configured limit. Match `MAX_EMAIL_BYTES` on Rails and Worker and check upstream request limits. |
| Worker reports 3xx | Point it directly at the final HTTPS ingress URL; redirects are intentionally rejected. |
| Worker times out | Check Rails availability and request latency. Its upstream request limit is 15 seconds; there is no durable inbound buffer. |
| Rails returns 200 but your product shows no message | Check ActionMailbox records, job workers, failed routing jobs and your mailbox's `process` method. The default mailbox only logs receipt. |
| Retrying creates no new inbound record | Identical MIME for the same SMTP recipient is intentionally deduplicated. |
| Bcc message appears routed to the wrong mailbox | Use `Envelope.for(inbound_email)["to"]` after checking the envelope exists; MIME `To` does not identify every SMTP recipient. |
| Quoted or internationalized addresses are rejected | The v2 envelope currently supports ASCII dot-atom addresses, not every possible email address syntax. |

## Local development

Restart Rails after upgrading so the ingress-only guard is installed. Start
Rails on the expected port before `cloudflare:email:dev`, install `cloudflared`,
and use development credentials and a development receiving route.

The tunnel only permits POSTs to the email ingress. Opening its root URL in a
browser returning 404 is expected. When you stop the tunnel, its URL remains in
the development Worker until the next update; it no longer reaches your app.

## Saved outbox operations

```sh
bin/rails cloudflare:email:pending_deliveries
```

This lists operations requiring attention for the configured account. It does
not dispatch or repair them automatically.

| State or error | What to do |
| --- | --- |
| `prepared` | The message is saved and can be dispatched using its existing operation key. Check for an enqueue failure or stopped worker. |
| `sending` | A process claimed the send. Verify its status; age alone does not prove it failed to send. |
| `unknown` | Collect provider evidence before making a resend decision. |
| `partial` | Review individual acceptance outcomes. Already accepted recipients must not receive a batch retry. |
| `accepted` | Repeated delivery uses the existing record without another send. Look at recipient lifecycle for later delivery results. |
| `rejected` | Correct the cause; a deliberate new attempt needs a new operation key. |
| `SnapshotConflict` | The same key was used with different MIME/envelope data. Retry the saved identity; do not re-render it. |

For a known `prepared` operation, dispatch the saved message with:

```sh
OPERATION_KEY='your-existing-operation-key' bin/rails cloudflare:email:deliver
```

For uncertainty, follow [audited reconciliation](outbox.md#reconcile-uncertainty).
Never reset a row to `prepared` or delete the ledger to make a retry go through.
Reconciliation requires an authorized operator and evidence; the gem records
the actor you supply but does not authenticate that person.

## Delivery updates

| What you see | What to check next |
| --- | --- |
| Queue stays empty | Check the Email Sending subscription, sending domain, selected event types and a real send from that domain. |
| Polling fails before processing | Check the queue ID, separate Queues Read/Write token, HTTP pull configuration and configured event handler. |
| Events process once then stop | `consume_events` is a one-batch task. Schedule it to run repeatedly. |
| Events stay unmatched | Check account, normalized provider message ID and recipient. Schedule replay; a receipt can arrive before the send result is saved. |
| Acknowledged event did not update the UI | Durable receipt storage and product projection are separate. Check replay, callback failures and application correlation. |
| Old delivery status does not replace a newer one | Ordering and terminal-state guards intentionally reject stale updates. |
| One event repeatedly fails | Inspect validation/handler errors and dead-letter queue policy. Invalid events are not acknowledged by the consumer. |

```sh
bin/rails cloudflare:email:consume_events
bin/rails cloudflare:email:replay_events
```

See [delivery events](delivery-events.md) for queue setup and
[observability](../README.md#observability-and-permissions) for notifications you
can connect to your monitoring. A delivery notification wraps handler execution;
it is not proof that queue acknowledgement completed.
