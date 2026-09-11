# Durable outbound email for Rails

The optional Active Record layer supplies immutable send snapshots, single-attempt delivery claims, recipient outcomes, delivery-event receipts, and audited reconciliation. Use it when background retries, process crashes, or missing provider responses must not silently resend an email. The plain Ruby client and ordinary ActionMailer delivery method remain available without these tables.

This is delivery infrastructure. Your application still authorizes sending, decides what belongs in a conversation, reviews drafts, and controls operator access.

## Install

After configuring the gem's sending credentials, generate both sets of tables:

```sh
bin/rails generate cloudflare:email:tracking
bin/rails generate cloudflare:email:outbox
bin/rails db:migrate
```

Skip a generator whose migration is already installed. The outbox initializer requires `cloudflare/email/active_record`, which loads the models, `Outbox`, `prepare_mail`, and `DeliveryEvents`, and also loads both jobs. For manual setup without the generator, require:

```ruby
require "cloudflare/email/active_record"
require "cloudflare/email/send_job"
require "cloudflare/email/replay_events_job"
```

Use a durable ActiveJob backend and a recurring scheduler suitable for your application. The gem does not install a job backend or Cloudflare Queue subscription. Configure delivery events and the separate queue token as described in [delivery-events.md](delivery-events.md).

## Prepare once, dispatch after commit

Render the mail, snapshot it together with your application update, and enqueue only after the outer database transaction commits:

```ruby
outbox = Cloudflare::Email::ActiveRecord::Outbox
account_id = Cloudflare::Email::Credentials.account_id

# Inside an application service that runs outside an existing transaction:
delivery = nil
Draft.transaction do
  draft.lock!
  # Apply the application's owner/approval checks here.
  mail = ReplyMailer.reply(draft).message
  delivery = outbox.prepare_mail(
    account_id: account_id,
    operation_key: "draft:#{draft.id}:revision:#{draft.revision}",
    mail: mail
  )
  draft.update!(outbound_operation_key: delivery.operation_key)
end

Cloudflare::Email::SendJob.perform_later(account_id, delivery.operation_key)
```

`Draft`, `revision`, and `outbound_operation_key` above are application examples, not generated gem models. For nested application transactions, use an actual after-commit hook; returning from an inner transaction does not necessarily commit the outer one.

`prepare_mail` accepts a rendered `Mail::Message` or an ActionMailer message delivery. It reads the SMTP envelope and encodes the MIME once, preserving attachments and To/Cc/Bcc delivery. It rejects `perform_deliveries == false`. Mailer rendering callbacks run during rendering; delivery callbacks are bypassed when sending the saved snapshot. Put required delivery authorization before preparation or in your application service.

For an existing MIME source:

```ruby
delivery = outbox.prepare(
  account_id: account_id,
  operation_key: "invoice:123:notification:1",
  from: "billing@example.com",
  recipients: ["customer@example.net"],
  mime_message: raw_mime
)
```

The account plus operation key identifies one immutable attempt. Preparing the same envelope and MIME returns the existing operation. Changing its snapshot raises `Outbox::SnapshotConflict`. Recipient order is preserved, duplicate addresses are removed, domains are lowercased, and local parts retain their case. MIME is stored as binary data. Re-rendering a mail can change generated headers, so job retries use the saved operation identity instead of calling the mailer again.

`Outbox.deliver(delivery, client: optional_client)` sends synchronously and refuses an ambient database transaction. Its `prepared → sending` claim commits before network I/O. A supplied client must match the account and expose `retry_ambiguous == false`. The standard `SendJob` uses the configured sending account/token and forces ambiguous retries off; applications managing several Cloudflare accounts can use their own account-aware job and pass the appropriate client.

## States and retries

| Operation state | Meaning and permitted action |
| --- | --- |
| `prepared` | Snapshot saved; safe to dispatch. |
| `sending` | A process claimed the attempt. Another job cannot send it. A crashed process can leave this state indefinitely. |
| `accepted` | All recipients have acceptance evidence. Repeated delivery returns the record without a network request. |
| `partial` | Some recipients have acceptance evidence, while others were rejected or remain unknown. Repeated delivery never resends the batch. |
| `rejected` | Available outcomes show rejection. The operation is terminal; correcting and sending again requires a new operation key. |
| `unknown` | Acceptance cannot be established safely. Investigate and reconcile before deciding on another attempt. |
| `confirmed_not_sent` | An operator confirmed the whole operation was not sent. Old jobs stay blocked; a deliberate new attempt needs a new key. |

Each `outbound_recipients` row stores `acceptance_state` separately from lifecycle `state`. A later complaint or bounce must not erase evidence that the original send was accepted. Lifecycle `occurred_at` stays nil for immediate send results and operator reconciliation: local clock time is not a provider event timestamp.

Malformed success responses, conflicting provider message IDs, timeouts, ambiguous transport errors, and failures saving an accepted response remain uncertain. Explicit supported provider rejection responses can produce `rejected`. Errors are re-raised after recording the conservative outcome. A database outage may leave the already committed `sending` claim instead of `unknown`; both block resend.

This is not exactly-once delivery. Provider acceptance and a database commit cannot be one transaction. Client pre-send/rate-limit retry behavior remains available, but automatic ambiguous retries are prohibited by the outbox.

## Recover dispatch and application projections

An application can commit its snapshot and crash before enqueueing. Schedule a scan of `prepared` operations and enqueue their saved identities. Multiple scanners/jobs are safe because only one can claim an operation. Do not reset `sending` operations merely because they are old.

Operational commands:

```sh
bin/rails cloudflare:email:pending_deliveries
OPERATION_KEY='invoice:123:notification:1' bin/rails cloudflare:email:deliver
bin/rails cloudflare:email:replay_events
```

The listing includes prepared, sending, unknown, and partial operations for the configured account; it does not automatically dispatch them. `deliver` uses `SendJob.perform_now` with the saved snapshot.

Optional Rails callbacks reduce application glue:

```ruby
settings = Rails.application.config.x.cloudflare_email
settings.outbox_delivery_handler = ->(delivery) {
  # Idempotently project the saved operation into application records.
}
settings.outbox_recipient_handler = ->(delivery, recipient) {
  # Project a lifecycle change into application records.
}
```

The delivery callback runs under a delivery row lock after the result has been saved. If application projection fails after acceptance, retrying the job repairs the projection without another provider send. The recipient callback runs inside receipt processing's transaction. Keep callbacks idempotent and use the same database connection for atomic application writes. External side effects cannot be rolled back; schedule them through a durable application mechanism.

## Consume and replay events

Wire the supplied projector into the event consumer:

```ruby
settings = Rails.application.config.x.cloudflare_email
settings.event_handler = ->(event) {
  Cloudflare::Email::ActiveRecord::DeliveryEvents.record(event) do |delivery, recipient|
    settings.outbox_recipient_handler&.call(delivery, recipient)
  end
}
```

`DeliveryEvents.record` commits the receipt before projecting it. Callback failures roll back projection and leave the saved receipt available for retry. It matches the account, normalized provider Message-ID, and recipient; ambiguous matches remain unmatched. Known events apply with lifecycle ordering and terminal-state guards. Event identity provides durable deduplication. Unknown future event statuses remain unmatched for later support.

An event may arrive before the send result is saved. `SendJob` replays matching receipts after its delivery callback, and a recurring `ReplayEventsJob.perform_later(account_id)` covers later recovery. Direct callers can use:

```ruby
Cloudflare::Email::ActiveRecord::DeliveryEvents.replay(
  account_id: account_id, message_id: delivery.provider_message_id
) do |operation, recipient|
  # Optional application projection.
end
```

Message-ID normalization removes surrounding angle brackets; it is correlation, not authorization. No provider ID means there is no safe automatic provider-ID match.

## Reconcile uncertainty

Restrict this operation to an authorized application operator. The gem records the supplied actor string; it does not authenticate that actor or verify external evidence.

```ruby
outbox.reconcile(
  delivery,
  outcome: :accepted,
  actor: "User:42",
  reason: "Provider support confirmed acceptance",
  evidence: "Support ticket 123 and retained provider response",
  provider_message_id: "provider-message-id",
  recipients: ["customer@example.net"]
) do |operation|
  # Optional application update, atomic with the audit and state change.
end
```

`outcome: :accepted` requires a valid provider Message-ID. `outcome: :not_sent` requires evidence of nonacceptance. Actor, reason, and evidence must be nonempty strings. Reconciliation can run inside an application transaction; callbacks and audit writes roll back together if it fails. Existing audit records are read-only through the model.

For a partial operation, only unresolved recipients can be reconciled. Omit `recipients` to select the unresolved subset. Known outcomes and lifecycle state are preserved; later decisions can resolve another unknown subset. A conflicting provider ID is refused. A batch with all recipients confirmed not sent becomes `confirmed_not_sent`; a mixed batch remains partial or otherwise reflects the remaining acceptance evidence. Never retry a complete partial batch to reach one unresolved recipient.

For a `sending` operation, first stop the original sender and verify it cannot resume. Reconciliation additionally requires `confirm_sender_stopped: true` and a claim at least 15 minutes old. Elapsed time alone is insufficient. There is no automatic lease expiry or timeout-based resend.

## Data ownership and migration

The gem owns its operation, recipient, receipt, and reconciliation infrastructure. The inbox owns mailbox permissions, conversations, approval policy, AI drafts, and UI. Link product records to operations by a stable key or application foreign key instead of copying the ledger algorithm.

The MIME snapshot contains email bodies, addresses, and attachments. Apply your application's database access, encryption, backup, and retention policies. Removing ledgers or replaying old backups can discard uncertainty and deduplication evidence; quiesce sending and reconcile provider activity during recovery.

Importing historical attempts is application-specific. If the old application did not save exact MIME, a reconstructed snapshot is historical metadata, not proof of the original bytes. Preserve its known/unknown state and do not turn imported accepted or uncertain attempts into dispatchable `prepared` operations. The generated outbox and receipt migrations refuse rollback to preserve delivery and deduplication evidence; use a forward fix or a reconciled backup.
