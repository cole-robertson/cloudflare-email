# Custom ingress and routing diagnostics verification

Scope: upstream gem integration tools informed by Rebulk's existing ingestion
pipeline. This report covers local synthetic verification, not a Rebulk rollout.

## Results

| Check | Result |
| --- | --- |
| Full Ruby suite, Ruby 3.4.1 / Rails 7.2, 8.0, 8.1 | Each: 257 tests, 916 assertions, no failures/errors/skips |
| Shared ingress unit tests | 12 tests, 98 assertions; independent Node/Ruby v3 binary/Unicode vector, tampering, metadata bounds, short streams, immutable results, retry identity |
| Custom Rails endpoint | 5 integration tests, 37 assertions; separate SQLite tenant databases, policy before persistence, durable signed metadata and retries |
| Built-in Rails endpoint | V3 persistence before routing enqueue, binary preservation, retries and unsigned v2 metadata rejection; covered in the full suite |
| Read-only routing diagnostics | 27 tests, 50 assertions; mocked Cloudflare configuration, exact-domain DNS, rule selection, ambiguous/inaccessible responses and pagination |
| Worker | 45 tests pass; Wrangler dry-run succeeds |
| Packaged consumer | Isolated plain Ruby install and packaged Rails installation/ingress fixtures pass |
| Local workerd → Rails | Real local forwarding, Bcc routing, attachment preservation, wrong/missing secrets, redirects and timeout handling pass |

Independent reviews found two verifier issues: a readable stream can return
short chunks, and HMAC must use the timestamp's exact transmitted bytes. Both
were corrected and covered by regression tests. Freshness still parses decimal
seconds; existing bundled Worker timestamps are unchanged.

## Reproduce

```sh
BUNDLE_GEMFILE=gemfiles/rails_7_2.gemfile bundle exec rake test
BUNDLE_GEMFILE=gemfiles/rails_8_0.gemfile bundle exec rake test
BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle exec rake test
bundle exec ruby script/verify_package.rb
BUNDLE_GEMFILE=gemfiles/local_ingress.gemfile bundle exec ruby script/verify_local_ingress.rb
npm --prefix templates/worker test
npm --prefix templates/worker run check
```

Use Node 22 for the Worker and local forwarding checks.

## Limits

No Rebulk application code, live DNS, Worker deployment, inbox activation, R2
archive, or gem publication was changed. The local workerd test exercises the
default v2 transport; opt-in v3 is covered by Worker tests, an independent shared
signature vector, and real Rails integration tests, not deployed Cloudflare mail.

Routing diagnostics inspect provider configuration through mocked API tests.
A passing configuration snapshot does not establish public DNS propagation,
complete SPF evaluation, Worker application behavior, or live delivery. Signed
metadata authenticates the forwarding integration's assertions; the host still
owns original-sender trust, held-message policy, and business processing.
