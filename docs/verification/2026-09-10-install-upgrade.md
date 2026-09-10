# Install, upgrade, rollback, and staged protocol rehearsal

Executed 2026-09-10 with Ruby 4.0.0, Rails 8.1.3.1, gem 0.2.0.
Gem merge: `cb8d8932296f64b5531ee2e1b773e9937c6df884`.
Inbox merge: `21bc3627ad70c586c45e7df297db4af4cd070066`.
The inbox retains its release-candidate gem pin `be879439353752d2127dd6413bf915f7321e3fa6`.

## Packaged install

```sh
bundle exec ruby script/verify_package.rb
```

Passed: isolated consumer installed the built `.gem` into a temporary bundle,
loaded version 0.2.0, and did not load Rails. Rails integration fixtures loaded
the extracted packaged files in separate processes:

| Fixture | Tests | Assertions | Failures/errors/skips |
| --- | ---: | ---: | --- |
| Inbound | 18 | 95 | 0/0/0 |
| Send only | 11 | 40 | 0/0/0 |
| Fresh inbound | 19 | 100 | 0/0/0 |

The fresh Rails harness invoked the actual install generator, installed and
ran Active Storage/Action Mailbox migrations, generated mailbox files and Worker
files, then received and routed a signed message. This verifies the packaged
generator in a minimal fresh Rails application; it does not claim a RubyGems
publication, Docker deployment, or a production installation.

## Existing inbox migration and backup recovery

From the gem checkout, using the inbox bundle:

```sh
INBOX_ROOT=/absolute/path/to/agentic-inbox-rails-full \
BUNDLE_GEMFILE=/absolute/path/to/agentic-inbox-rails-full/Gemfile \
bundle exec ruby script/verification/install_upgrade.rb
```

All **16 checks passed**. The script creates temporary SQLite databases and
storage, uses inert test credentials, disables mail delivery, and blocks network
access during routing. It removes those resources on exit and never migrates the
configured inbox database.

- Migrate a completely empty database to the pre-ledger migration
  `20260418012251`; insert representative incoming, sent, and unapproved messages.
- Upgrade to the current schema; preserve every original message field and
  timestamp. Previously sent messages become `legacy_sent`, while unsent messages
  become `pending`. No provider IDs or delivery attempts are fabricated.
- Check review-field defaults on existing rows.
- Insert an ambiguous send and durable attempt. Take a quiesced SQLite snapshot
  with `VACUUM INTO`, roll back both new migrations, and reapply them.
- Restore the snapshot into a different database; verify the original ambiguous
  attempt and message state survive. Re-running migrations is idempotent, and an
  actual `DraftDelivery.call` remains blocked without creating another attempt.

**Schema rollback is destructive to delivery history.** The rehearsal confirmed
that down/up migrations preserve old message content but drop attempts and reset
an ambiguous draft to `pending`. A schema rollback after send attempts exist must
not be treated as a safe retry/recovery procedure. Stop writers and retain the
ledger; prefer a forward fix. If restoring a backup, coordinate ingress, jobs,
and provider reconciliation first: the local quiesced backup test does not prove
that restoring an earlier production snapshot is safe while external sends are
in flight. Rolling back to old sending code can also bypass the new ledger guard.

## Rails-before-Worker rollout

The same script POSTs correctly signed v1/v2 payloads to the real Rails ingress
and routes them through `AgentMailbox`. A closed, existing conversation avoids
LLM requests and outbound mail.

| Protocol and configuration | Observed result |
| --- | --- |
| v1, `ALLOW_LEGACY_EMAIL_ROUTING=true`, single To/no Cc | Accepted and routed into the existing conversation |
| v1, transitional mode, Cc present | Ingress accepts; mailbox refuses ambiguous routing and records bounced |
| v1, strict mode | Ingress accepts; mailbox refuses missing authenticated envelope and records bounced |
| v2, strict mode | Accepted and routed into the existing conversation |

Only the two permitted messages enter the conversation; no outbound mail is sent.
For a staged rollout, deploy Rails with the explicitly temporary legacy flag,
deploy the v2 Worker, verify authenticated-envelope delivery, then disable the
flag. Legacy multi-recipient traffic is intentionally refused even during this
transition; use a controlled ingress pause if this traffic must not be interrupted.
The protocol replay tests exercise real HMAC verification, persistence, and
mailbox execution, with synthetic local HTTP requests; they are not additional
Cloudflare-deployed Worker tests.
