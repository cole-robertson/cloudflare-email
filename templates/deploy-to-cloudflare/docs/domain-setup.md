# Set up addresses and customer subdomains

Choose the address pattern for your app:

| Pattern | Example | Rails setup |
| --- | --- | --- |
| One receiving domain | `acme@in.example.com` | Register the domain once; create a mailbox for each customer |
| Customer subdomains | `invoices@acme.in.example.com` | Register each exact customer domain and its mailboxes |

One Worker can serve all your accepted addresses. Rails looks up the mailbox;
you do not need to maintain an address list in the Worker.
Database multi-tenancy is optional.

## 1. Deploy the Worker

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/cole-robertson/cloudflare-email/tree/main/templates/deploy-to-cloudflare)

Deploy Rails first, then enter its HTTPS ingress URL and shared secret in the
Worker deployment form. Cloudflare provisions private R2 storage and a Queue.
Use separate deployments for development and production.

The [setup guide](https://github.com/cole-robertson/cloudflare-email/tree/main/templates/deploy-to-cloudflare)
covers the form and required resources.

## 2. Connect your receiving domain

Use a subdomain such as `in.example.com` if your main domain already receives
mail through Google Workspace or Microsoft 365.

In Cloudflare Email Routing:

1. [Add the receiving domain or subdomain](https://developers.cloudflare.com/email-service/configuration/subdomains/).
2. Add the DNS records Cloudflare provides, preserving your main domain's mail records.
3. Create a route with **Send to a Worker** and select your deployed Worker.
4. To accept many local parts, configure the receiving domain's
   [catch-all rule](https://developers.cloudflare.com/email-service/configuration/email-routing-addresses/#catch-all-rule)
   to use that Worker.

A Cloudflare catch-all gets email to your Worker. Rails still decides which
addresses are accepted. To put unknown local parts into an inbox, also enable
the gem's [mailbox catch-all](https://github.com/cole-robertson/cloudflare-email/blob/main/docs/mailboxes.md#receive-unregistered-local-parts-with-an-optional-catch-all).

## 3. Customer subdomains

Cloudflare documents explicit subdomain onboarding. If you want new customer
subdomains to work without adding each one in Cloudflare, verify wildcard
receiving on your account before relying on it.

For a receiving namespace under `in.example.com`, the DNS pattern is:

| Type | Name in zone `example.com` | Value |
| --- | --- | --- |
| MX | `*.in` | Each receiving MX target and priority assigned by Cloudflare |

Wildcard DNS alone does not guarantee Email Routing accepts an unlisted
subdomain. Test with a fresh customer subdomain and confirm email reaches the
Worker and the correct Rails inbox. If your account requires explicit onboarding,
add those subdomains in Cloudflare or use the single-domain pattern.

[Explicit DNS records override wildcard inheritance](https://developers.cloudflare.com/dns/manage-dns-records/reference/wildcard-dns-records/),
including names with A or TXT records. Check existing customer names as well as
new ones. The receiving base `in.example.com` needs its own records.

### Check DNS

From either Worker template:

```sh
npm run check:subdomains -- --base in.example.com --labels acme,globex
```

This checks your chosen labels and two fresh labels without changing DNS.
It needs Node and DNS access, with no API key. A passing result confirms MX
answers; send a real email to verify delivery.

For configured Worker rules, use the
[Rails routing diagnostic](https://github.com/cole-robertson/cloudflare-email/blob/main/docs/routing-diagnostics.md).
That check inspects exact DNS records, so inherited wildcard MX may appear missing.

## 4. Create the mailbox in Rails

After verifying the receiving route, run this from trusted application setup code:

```ruby
registry = Cloudflare::Email::Mailboxes
domain = registry.register_domain(
  domain: "acme.in.example.com",
  tenant_key: "organization-123"
)
registry.activate_domain!(domain.id, evidence: "Receiving route verified")

registry.for_tenant("organization-123") do |inboxes|
  mailbox = inboxes.create(
    name: "Invoices",
    address: "invoices@acme.in.example.com",
    owner_ref: "Organization:123"
  )
  inboxes.activate_address!(mailbox.addresses.first.id,
    evidence: "Receiving route verified")
end
```

Use your application's stable organization identity and validate customer slugs.
Activation records the verification you performed; it does not configure DNS.
Registration takes exact domains, not `*` patterns.

Once wildcard receiving is verified, create new customer domains and mailboxes
through these same APIs. Send a test message and confirm it appears only in the
intended inbox. Monitor pending mail so unregistered or suspended destinations
can be resolved.

## Sending from customer addresses

Receiving and sending are separate. Cloudflare requires
[verification of each sending domain](https://developers.cloudflare.com/email-service/configuration/subdomains/#add-a-subdomain-to-email-sending).
A simple setup uses a shared verified From address and a customer-specific
Reply-To address. To send through a managed mailbox, follow the
[mailbox sending setup](https://github.com/cole-robertson/cloudflare-email/blob/main/docs/mailboxes.md#send-from-the-mailbox).
