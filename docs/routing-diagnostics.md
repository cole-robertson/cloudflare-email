# Check whether an address is configured to reach your Worker

This diagnostic is unreleased and is not included in gem version 0.2.0.

A mailbox registered in Rails is not proof that Cloudflare can deliver to it.
Use this read-only check when onboarding a receiving domain, investigating a
missing message, or checking an existing catch-all before activating addresses.

```sh
bin/rails cloudflare:email:check_route \
  ADDRESS=houston@customer.example.com \
  WORKER_NAME=cloudflare-email-ingress-production \
  ACCOUNT_ID=your-cloudflare-account-id
```

Configure your Cloudflare management token in the normal gem credentials. The
inspection needs Zone Read, DNS Read, and Email Routing Read permissions. No Edit
permissions are needed. `WORKER_NAME` defaults to the gem's environment-scoped
Worker name; `ACCOUNT_ID` falls back to the configured account, if present.

Every check reports `PASS`, `FAIL`, or `UNKNOWN`. The command exits zero only
when all configuration checks pass. An unavailable API, insufficient permission,
an unsupported matcher, or ambiguous rule ordering produces `UNKNOWN`, not a
successful result. Output excludes raw provider responses and credentials.

The check inspects:

- The closest containing Cloudflare zone and its account when an expected account is supplied.
- Whether Email Routing is enabled for the zone.
- MX and SPF records for the **exact receiving domain**. Parent-domain records
  cannot satisfy a subdomain's requirements, and a parent's unrelated MX provider
  does not conflict with correctly configured subdomain records.
- Active explicit address rules before falling back to the catch-all. An explicit
  drop, forwarding action, or different Worker takes precedence over a correct
  catch-all. Disabled explicit rules are ignored. Multiple matching rules or
  unsupported matcher forms leave selection unverified rather than guessing
  priority or tie behavior.

List reads are paginated and bounded to 50 pages per endpoint, responses to 1 MiB,
and each request to 20 seconds (with shorter connection/read timeouts). An
incomplete inspection does not report success. This command only issues GET
requests. It never enables routing, changes DNS, repairs rules, or activates
mailbox records.

## Use from Ruby

```ruby
require "cloudflare/email/routing_diagnostics"

report = Cloudflare::Email::RoutingDiagnostics.new(
  api_token: ENV.fetch("CLOUDFLARE_API_TOKEN")
).check(
  address: "houston@customer.example.com",
  worker_name: "cloudflare-email-ingress-production",
  account_id: ENV.fetch("CLOUDFLARE_ACCOUNT_ID")
)

report[:status] # "pass", "fail", or "unknown"
report[:checks] # [{ name: "zone", status: "pass", message: "..." }, ...]
```

This API does not require Active Record or enable multi-tenancy. You can use it
with a custom Worker and an existing application ingestion pipeline. It reports
a provider configuration snapshot; it does **not** prove public DNS propagation,
full SPF evaluation, successful live delivery, the Worker's application URL or
behavior, or application acceptance. Keep those as separate checks, including a
controlled end-to-end delivery when appropriate. A passing report does not
automatically change mailbox readiness or constitute delivery evidence.
