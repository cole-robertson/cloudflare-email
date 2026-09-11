# Preproduction cleanup and reusable event receipts — September 11, 2026

This pass removes v1 ingress and SecureMessageId, adds optional ActiveRecord event
receipts, and extracts provider acceptance, message-ID normalization and delivery
ordering helpers. See [architecture](../architecture.md) for the implemented
boundary and the next outbound-ledger extraction.

## Local checks

| Check | Result |
| --- | --- |
| `bundle exec rake test`, Ruby 3.4.1 / Rails 8.1.3.1 | 189 tests, 635 assertions, no failures/errors/skips |
| Durable event adapter subprocess included in suite | 13 SQLite tests, 56 assertions |
| `bundle exec ruby script/verify_package.rb` | Isolated Ruby consumer and Rails package checks passed; 48 tests, 235 assertions |
| `script/verification/install_upgrade.rb` under Ruby 4 / Rails 8.1 | 16 checks passed, including v1 rejection and v2 inbox routing |
| Local actual workerd → Rails | 19 checks passed using Node 22.23.1 |

Receipt tests exercise the generated migration, account-scoped database uniqueness,
concurrent duplicate insertion, changed-payload rejection, commit-before-ACK,
failed persistence preventing ACK, replay, savepoint/handler rollback, and explicit
handler outcomes. Plain gem loading is checked without ActiveRecord.

The Worker run verifies authenticated SMTP metadata, unchanged MIME and all 256
binary byte values, same-recipient deduplication, separate Bcc recipient records,
mailbox-job execution, secret mismatch, redirect rejection, and a real 15-second
timeout. The first invocation found Node 20 on PATH and failed before Worker
startup; rerunning with explicit installed Node 22.23.1 passed.

These are local checks using synthetic mail, SQLite and controlled HTTP responses.
No email was sent, no Worker deployed, and no RubyGem published in this pass.
PostgreSQL locking and live delivery using this new adapter have not been verified.
Earlier live reports remain evidence for their dated revisions only.
