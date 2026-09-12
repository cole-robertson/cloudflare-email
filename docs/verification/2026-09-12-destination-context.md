# Destination context and email persistence verification

Scope: standalone accepted-address resolution and destination context yielded
from the existing persisted receive path. No Rebulk deployment or gem release.

## Results

- Full suites on Ruby 3.4.1 with Rails 7.2, 8.0 and 8.1: each passed with
  257 top-level tests and 916 assertions. These include subprocess integration
  fixtures whose internal assertions are not included in that top-level count.
- The standalone service fixture uses two real SQLite tenant databases with
  colliding mailbox IDs and no ActionMailbox loaded. It verifies host-owned
  binary-email persistence, immutable destinations, aliases, inactive records,
  nested context restoration, host exceptions and missing-tenant refusal without
  creating a database. Lookup itself creates no mailbox membership.
- The custom Rails ingress fixture verifies saved raw MIME and signed metadata,
  mailbox membership, and a host business link created from the destination.
  Routing jobs execute in the correct tenant after commit. Retries do not
  duplicate the linked records. A host write failure rolls back the email and
  membership and schedules no routing job.
- Existing callbacks remain supported, including strict zero-argument lambdas.
- Packaged plain Ruby and Rails consumer checks pass, including mailbox ingress,
  routing and existing retention behavior.
- Independent review found no remaining blockers. A callback arity compatibility
  issue was fixed and covered before completion.

## Reproduce

```sh
BUNDLE_GEMFILE=gemfiles/rails_7_2.gemfile bundle exec rake test
BUNDLE_GEMFILE=gemfiles/rails_8_0.gemfile bundle exec rake test
BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle exec rake test
bundle exec ruby script/verify_package.rb
```

## Boundaries

Destination context is a lifecycle snapshot, not host authorization or a durable
processing claim. Applications still validate owners and sender policy and make
downstream work idempotent. The host owns custom-store transactions; `receive`
preserves the existing shared tenant transaction for ActionMailbox persistence.
Neither API makes cross-database or external object-store operations atomic.

Managed mailbox memberships protect raw email from automatic incineration;
deliberate purge, backups and host-reference cleanup remain application policy.
These local tests do not verify Rebulk's actual queues, sender policy or archive.
