# Cloudflare Email for Rails

Receive email in Rails with the [cloudflare-email gem](https://github.com/cole-robertson/cloudflare-email).
This template stores inbound mail in private R2, delivers it through a Queue,
and retries from storage when Rails is unavailable. It includes scheduled
recovery and Worker logs. No React app or extra server is needed.

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/cole-robertson/cloudflare-email/tree/main/templates/deploy-to-cloudflare)

## 1. Prepare Rails

Install `gem "cloudflare-email", "~> 0.3.0"` and follow the
[Rails setup guide](https://github.com/cole-robertson/cloudflare-email/blob/main/docs/getting-started.md).
Deploy Rails with Action Mailbox storage and routing configured before connecting
real email. Generate a secret with `openssl rand -hex 32` and configure it as
`cloudflare.ingress_secret` in Rails credentials or `CLOUDFLARE_INGRESS_SECRET`.
Keep the same value for the deployment form.

## 2. Deploy the Worker

Click the button and sign in to Cloudflare and GitHub/GitLab as prompted.
Cloudflare copies this directory into your own repository, provisions the R2
bucket and Queue, and builds the Worker. Enter:

- **RAILS_INGRESS_URL:** your public HTTPS endpoint, normally
  `https://your-app.com/rails/action_mailbox/cloudflare/inbound_emails`.
- **INGRESS_SECRET:** the exact secret you configured in Rails.

Choose distinct Worker, bucket, and Queue names for each app/environment. This
template has one environment per deployment; deploy separate copies for staging
and production. R2 and Queues must be available on your account and their usage
can incur charges. Review Cloudflare's resource and billing prompts.

The form uses `npm run deploy`; no `--env` argument is required for this template.
After deployment, confirm both bindings, the Queue consumer, and the once-per-minute
cron are present. Keep the bucket private with no lifecycle rule expiring
`cloudflare-email/pending/` objects. The Worker has no public email-submit HTTP API.

## 3. Connect an email address

**Choose your address shape:** `acme@in.example.com` on one receiving domain,
or `invoices@acme.in.example.com` with dynamic organization subdomains.
Use the [shared domain setup guide](docs/domain-setup.md) for the setup worksheet,
Cloudflare DNS/routing steps, cited Rebulk example, and verification commands.
The same Worker serves both; there is no per-organization Worker allowlist.

In Cloudflare, enable Email Routing for the intended receiving domain/subdomain
and complete its required DNS setup. Add an Email Routing rule for your receiving
address with **Send to a Worker**, selecting the Worker you just deployed. For
many local parts, configure the intended domain's catch-all to this Worker once.
The button does not change your MX records, provision addresses in Rails, or
replace your existing mailbox provider. Use a receiving subdomain when your apex
domain's email belongs to Google Workspace or Microsoft 365.

If using the gem's managed mailboxes, register the receiving mailbox/address in
Rails too. Tenant support and domain catch-all receiving remain explicit choices.
After verifying a dynamic namespace as described in the guide, register new
organization domains in Rails without routinely adding provider rules per org.
Wildcard DNS behavior must be verified on your Cloudflare account; the guide
distinguishes working Rebulk evidence from Cloudflare's explicit onboarding docs.
Outbound Email Sending credentials and delivery-event subscriptions are separate
from this inbound Worker setup.

## 4. Verify and operate

For dynamic organization subdomains, start with the read-only DNS check:

```sh
npm run check:subdomains -- --base in.example.com --labels acme,globex
```

It checks named and fresh labels without API credentials or configuration changes.
It reports DNS observations only; finish with the real-email checks below.

Send to the configured address and verify that Rails retains and routes it.
In staging, stop Rails, send another message, confirm it remains in R2, restore
Rails, and confirm one inbox record and removal of the pending object. Verify a
retry does not duplicate application work. Monitor Worker errors and pending R2
count/age; Queue depth alone misses mail whose queue retries are exhausted.

Read the [durable delivery and recovery guide](https://github.com/cole-robertson/cloudflare-email/blob/main/templates/worker/docs/durable-inbound.md)
for recovery limits, retention, failure drills, and the explicit direct fallback.
In this standalone template, configure bindings at the top level and run
`npm run deploy` without `--env`. Do not remove storage or cron while mail is pending.
Delivery is at least once, with Rails deduplication; application handlers must
also tolerate retries. Configure operational alerts in your monitoring service.

## Updates and local development

Your copied repository belongs to you; gem updates do not update its Worker
automatically. Review upstream release notes, deploy Rails first, then port Worker
changes into your copy while preserving your resource names, secrets, and pending
storage. Keep production resources separate from test resources.

Use Node 22.12+ (or a supported newer version): `npm ci`, `npm test`, and
`npm run check`. For local development, copy `.dev.vars.example` to `.dev.vars`,
set local values, and run `npm run dev`. Never commit secrets.

Upstream maintainers: `templates/worker` is the canonical runtime. Run
`node script/sync_deploy_template.mjs` from the gem repository after modifying its
runtime, tests, dependencies, or production bindings. CI rejects drift and tests
this directory after copying it outside the repository, matching Cloudflare's
subdirectory deployment model. Edit this README directly; generated files are
marked by the sync script's file list.
