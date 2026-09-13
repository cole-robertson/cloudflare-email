# Set up once, create mailboxes in Rails

Use the same Worker for either address shape:

| Pattern | Example | What changes when a customer joins |
| --- | --- | --- |
| One receiving domain | `acme@in.example.com` | Create a mailbox/address in Rails |
| Organization subdomains | `invoices@acme.in.example.com` | Register the exact organization domain and its mailboxes in Rails, within your verified receiving namespace |

Neither pattern needs a recipient allowlist in the Worker. Rails owns accepted
addresses and organization membership. Database multi-tenancy remains optional.
The [Rails hello-world template](https://github.com/cole-robertson/cloudflare-email-rails-starter)
demonstrates the first pattern with a normal SQLite database and generated login.

## What is verified, and what Cloudflare documents

**Rebulk's existing deployment uses the second pattern:**
`<site>@<organization>.rebulk.com`, wildcard MX, a catch-all Worker rule, and Rails
organization/mailbox lookup. New organizations do not need a Worker enrollment
list or a routine per-organization Cloudflare approval. Its September 2026
rehearsal checked exact-domain public MX answers and archived SMTP-envelope
delivery evidence, alongside the global catch-all rule. The apex keeps its
separate mail provider. Sources (Rebulk repository access required):

- [Worker architecture and organization setup](https://github.com/Rebulk/rebulk-system/blob/1cc26e0076ba0e9157e89f5879604df8c94430bc/cloudflare/README.md).
- [Wildcard MX observations and limits of zone-level API evidence](https://github.com/Rebulk/rebulk-system/blob/1cc26e0076ba0e9157e89f5879604df8c94430bc/docs/cloudflare-mailbox-onboarding-rehearsal-2026-09-12.md).

This is deployment evidence, not a Cloudflare-wide service guarantee. Cloudflare's
[subdomain onboarding guide](https://developers.cloudflare.com/email-service/configuration/subdomains/)
describes adding subdomains explicitly and currently lists a 30-domain combined
Routing/Sending limit. It does not document arbitrary wildcard Email Routing as
a way to bypass that limit. Cloudflare separately documents
[wildcard DNS and exact-record precedence](https://developers.cloudflare.com/dns/manage-dns-records/reference/wildcard-dns-records/).
Working wildcard DNS alone does not establish Email Routing acceptance. If your
account does not accept unlisted subdomains, use documented explicit onboarding
within its limits, or the single-domain pattern. Do not assume that an existing
Rebulk setup proves a fresh account's behavior.

A fresh [public DNS observation](https://github.com/cole-robertson/cloudflare-email/blob/main/docs/verification/2026-09-13-wildcard-dns.json)
also records Cloudflare MX answers for `test.rebulk.com` and two random subdomains
without creating DNS records or adding those labels in Cloudflare. That report
is public and deliberately marks `delivery_verified: false`; no email was sent
by this DNS-only check.

## 1. Fill in your setup worksheet

Use a dedicated receiving namespace when the apex already serves Workspace or
Microsoft 365. Example values:

| Setting | Your example value |
| --- | --- |
| Cloudflare zone | `example.com` |
| Receiving base | `in.example.com` |
| Organization domain | `acme.in.example.com` |
| Worker | `cloudflare-email-ingress` |
| Rails ingress URL | `https://app.example.com/rails/action_mailbox/cloudflare/inbound_emails` |
| Shared ingress secret | Generate with `openssl rand -hex 32`; save privately in Rails and the Worker |

Keep staging and production Workers, buckets, queues, secrets, and receiving
namespaces separate. The standalone deploy-button template takes one environment
per copy; the regular CLI template uses `--env production` or another explicit env.

## 2. Deploy the shared infrastructure

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/cole-robertson/cloudflare-email/tree/main/templates/deploy-to-cloudflare)

Deploy Rails with gem 0.3+ first. The button copies the standalone Worker and
prompts for `RAILS_INGRESS_URL` and `INGRESS_SECRET`. Its configuration includes
private R2 storage, a Queue producer/consumer, once-per-minute recovery, and logs.
Cloudflare documents [automatic R2/Queue provisioning and secret prompts](https://developers.cloudflare.com/workers/platform/deploy-buttons/).
The button does not create email DNS, claim a domain, or register Rails mailboxes.

## 3. Connect DNS and the Worker once

For **one domain**, follow Cloudflare's documented
[Email Routing onboarding](https://developers.cloudflare.com/email-service/get-started/route-emails/)
and configure its [catch-all action](https://developers.cloudflare.com/email-service/configuration/email-routing-addresses/#catch-all-rule)
as **Send to a Worker**, selecting your deployed Worker. This avoids one provider
rule per local part. Review the actual zone/domain scope and any explicit rules
that take precedence before saving.

For a **Rebulk-style dynamic namespace**, first establish receiving on your account
and retain the exact MX targets/priorities assigned by Cloudflare. Then, when
reproducing and verifying wildcard receiving, the DNS template is:

| DNS type | Name in zone `example.com` | Value |
| --- | --- | --- |
| MX | `*.in` | Each Cloudflare-assigned receiving MX target, with its assigned priority |

Create one record per assigned target. Do not invent MX targets, point MX at a
Worker URL, or replace the apex's existing MX records. Complete the service's
other required DNS records through its onboarding instructions; do not blindly
duplicate SPF records. Inspect the account's catch-all **Send to a Worker** rule
and verify that it actually handles your intended namespace. A Cloudflare Worker
HTTP route such as `*.example.com/*` is unrelated to email routing.

An explicit DNS name can stop wildcard inheritance **even if its record is TXT
or A rather than MX**. For example, an existing `acme.in.example.com` record may
require its own receiving MX records. Test exact customer names as well as fresh
ones. A wildcard also does not supply MX for the receiving base itself.

## 4. Check without modifying infrastructure

From either current Worker template, run:

```sh
npm run check:subdomains -- --base in.example.com --labels acme,globex
```

This requires only Node and DNS access, not a Cloudflare API key. It resolves MX
for your chosen labels plus two fresh random labels. DNS lookups have bounded
timeouts. JSON output distinguishes observed Cloudflare MX, other/missing MX, and
lookup uncertainty. Exit zero means only that all queried names resolved to
Cloudflare MX; `delivery_verified` remains false. Compare returned targets with
your account's assigned targets. Existing explicit records can explain differences.
The command ships in the repository templates; gem 0.3.0's already-published
template predates it, so refresh your template copy to use it.

For provider rule inspection, the gem also offers:

```sh
bin/rails cloudflare:email:check_route \
  ADDRESS=invoices@acme.in.example.com \
  WORKER_NAME=cloudflare-email-ingress \
  ACCOUNT_ID=your-cloudflare-account-id
```

See [diagnostic credentials and limits](https://github.com/cole-robertson/cloudflare-email/blob/main/docs/routing-diagnostics.md).
That diagnostic inspects exact-domain configured records; it does not resolve
wildcard DNS inheritance. A working inherited-MX setup can therefore report
missing exact records. Keep public DNS, provider rule inspection, and actual
delivery evidence separate; do not force every organization through Cloudflare
onboarding merely to make that diagnostic green.

## 5. Prove the dynamic path before adopting it

Use two new organization labels that have not been added individually in the
Cloudflare dashboard:

1. Check their public MX answers with the command above.
2. Through trusted provisioning code, register both **exact** domains in Rails,
   each against the correct stable organization key. Create a test mailbox for
   each. Record your independently checked configuration evidence and activate
   those test addresses so the gem can receive the verification messages.
3. Send real email to both addresses from an external mailbox. Confirm the
   Worker receives each, Rails retains the original message, and each appears
   only in the correct organization's inbox. Record the message IDs and result.
4. Repeat with a newly generated label without changing Cloudflare. If delivery
   fails before the Worker, resolve the Cloudflare acceptance/onboarding issue;
   changing Rails cannot fix a provider SMTP rejection.
5. Rehearse Rails being unavailable, then verify retained R2 mail drains after
   recovery without duplicate app records. Follow the
   [durable recovery guide](https://github.com/cole-robertson/cloudflare-email/blob/main/templates/worker/docs/durable-inbound.md).

These are deliberate test addresses; no real-email test is sent by the DNS checker.
Successful tests establish evidence for your receiving namespace, not a guarantee
that every future DNS change or provider policy will preserve it.

## 6. Create organizations in Rails

Once your namespace policy is verified, use the same gem APIs on organization
creation. For example, from trusted app code after authorizing the organization:

```ruby
registry = Cloudflare::Email::Mailboxes
organization_key = "organization-123" # Trusted stable app identity, not request input.
domain = registry.register_domain(
  domain: "acme.in.example.com",
  tenant_key: organization_key,
  account_id: Cloudflare::Email::Credentials.account_id
)
registry.activate_domain!(domain.id, evidence: verified_namespace_evidence)
registry.for_tenant(organization_key) do |inboxes|
  mailbox = inboxes.create(name: "Invoices", address: "invoices@acme.in.example.com",
    owner_ref: "Organization:123")
  inboxes.activate_address!(inboxes.addresses(mailbox.id).first.id,
    evidence: verified_namespace_evidence)
end
```

`verified_namespace_evidence` is your stored operator evidence from the setup and
delivery checks, not a hard-coded claim of success. Make provisioning idempotent
in your app, validate/reserve slugs, and resolve organization identity from trusted
records. The gem stores exact domain registrations; it does not accept a `*`
domain registration or silently authorize an arbitrary recipient from a web form.
The management engine must obtain allowed domains from your host adapter. The
hello-world starter intentionally stays single-domain; this recipe is the next
step for an organization-aware app.

A **Cloudflare routing catch-all** gets mail to the Worker. The gem's optional
**mailbox catch-all** decides whether unknown local parts enter a mailbox. They
are separate. Without the latter, unknown/suspended recipients return non-2xx and
remain in durable pending storage until resolved. Monitor that backlog.

Receiving on dynamic domains does not authorize sending from them. Cloudflare
[Email Sending onboarding](https://developers.cloudflare.com/email-service/configuration/subdomains/#add-a-subdomain-to-email-sending)
is separate; keep a verified shared sending domain unless you have explicitly
onboarded the customer sending domain.
