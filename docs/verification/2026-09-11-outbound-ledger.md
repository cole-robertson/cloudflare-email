# Shared outbound ledger verification — September 11, 2026

The optional Rails layer now owns immutable MIME preparation, account-scoped
operation keys, committed send claims, recipient acceptance evidence, provider
event projection, and audited reconciliation. The reference inbox consumes these
tables and services rather than keeping its own transport ledger.

## Local results

| Check | Result |
| --- | --- |
| Gem suite, Ruby 3.4.1 / Rails 8.1.3.1 | 191 tests, 637 assertions, no failures/errors/skips |
| Outbox subprocess included in suite | 21 SQLite tests, 112 assertions |
| Mail snapshots, jobs, event projection subprocess | 9 SQLite tests, 45 assertions |
| Existing receipt subprocess | 13 SQLite tests, 56 assertions |
| Actual PostgreSQL 15 verifier | 9 tests, 45 assertions |
| Packaged isolated Ruby + Rails install/ingress + outbound checks | 57 tests, 280 assertions; all passed |

The top-level gem counts include subprocess assertions, not their individual
inner assertions. PostgreSQL 16 verification is added to CI. The PostgreSQL
driver remains an optional test dependency; the gem has no new runtime database
or job dependencies for plain Ruby users.

## Failure and concurrency coverage

- Eight concurrent identical operations produce one stored snapshot and one
  provider request. Conflicting snapshots cannot overwrite the winner.
- Independent operations reach the controlled provider concurrently.
- A real SIGKILL after the durable claim leaves the operation blocked after
  restart. A real PostgreSQL backend termination plus simulated provider timeout
  also preserves the non-retryable claim.
- Acceptance followed by database failure does not permit another send.
- Partial acceptance never resends the whole batch. Unknown recipients can be
  reconciled independently while known lifecycle states remain intact.
- Malformed IDs and conflicting per-recipient provider IDs become uncertainty;
  a valid common ID on a later recipient entry is retained.
- Event-before-response, duplicate callbacks, concurrent out-of-order events,
  terminal guards, account mismatch and ambiguous IDs are exercised.
- Application callback failure rolls back product and recipient writes while
  retaining the receipt; replay applies it. A send-job retry repairs failed
  product projection without another provider request.
- MIME includes a binary attachment containing all 256 byte values and a hidden
  Bcc envelope recipient. Jobs serialize only the account and operation key.
- Reconciliation requires actor/reason/evidence and legal unresolved transitions.
  Sending reconciliation requires a stopped sender confirmation and a minimum
  claim age. Generated migrations refuse to delete safety evidence on rollback.

## Boundaries

HTTP acceptance and lifecycle payloads use controlled local fixtures. This pass
does not send live mail, deploy a Worker, publish RubyGems, or prove inbox placement.
Earlier Cloudflare live reports describe their own revisions. Provider-ID
correlation assumes Cloudflare assigns unique IDs; pre-existing duplicate matches
are retained as unmatched for review. The network and database remain separate
transactions, and the system does not claim exactly-once provider delivery.

The reference inbox has separate HTTP, browser, process-recovery and import
verification recorded in its `docs/verification/2026-09-11-outbox.md`. Historical
records preserve available content and audit data; reconstructed imported MIME
is explicitly marked and is not claimed to reproduce historical wire bytes.
