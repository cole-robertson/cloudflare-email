# Create and manage mailboxes from Rails

The optional mailbox module lets your app create mailboxes and aliases, receive
mail into them, track read/archive state, and send through the durable outbox.
It works in one SQLite database or with a separate database per organization.
It supplies models and services; your app supplies permissions and the UI.

This module is available in version 0.2.0. Install `gem "cloudflare-email", "~> 0.2.0"`.

**Database multi-tenancy is off by default.** The mailbox generator works with
one ordinary database. Calling `for_tenant` groups and scopes mailbox records;
it does not create databases or install a tenant adapter. Separate databases
require explicit `Tenancy.configure(...)` before models load. Neither Rails nor
`activerecord-tenanted` is added to plain Ruby applications by this module.

## Install

First configure [sending and receiving](getting-started.md). Then run:

```sh
bin/rails generate cloudflare:email:mailboxes
bin/rails db:migrate
```

The generator includes the outbox and tracking generators. Do not generate those
migrations a second time if you already installed them; inspect existing
generator conflicts and retain your installed migrations. Restart Rails after
configuration changes. The generated initializer explicitly loads:

```ruby
require "cloudflare/email/mailboxes"
```

Loading this module enables mailbox lookup on the gem's Cloudflare ingress.
Existing receiving addresses must be registered and activated before switching
an existing application over. Unregistered or suspended destinations return
HTTP 422 and the Worker rejects the delivery; there is no default-mailbox fallback.

For separate organization databases, follow the
[activerecord-tenanted setup](activerecord-tenanted.md) **before loading the
models**. It covers shared versus tenant migrations, tenant-specific framework
storage, early initialization and background jobs. Rails and ActiveStorage must
use the same tenant connection as the mailbox tables for atomic incoming storage.

## Register an organization's domain

Run directory management from your authorized administration/provisioning code.
Do not expose arbitrary domain claims to customers without ownership checks.

```ruby
inboxes = Cloudflare::Email::Mailboxes
domain = inboxes.register_domain(
  domain: "acme.example.com",
  tenant_key: "organization-123",
  account_id: Cloudflare::Email::Credentials.account_id,
)
```

This creates a **pending directory entry**, not DNS records. Set up the receiving
subdomain in Cloudflare and deploy the Worker. Then record your verification:

```ruby
inboxes.activate_domain!(domain.id,
  evidence: "Receiving DNS and the development Worker verified in setup ticket 42",
  sending_enabled: false,
)
```

Activation records an operator assertion; the gem does not independently verify
domain ownership from this string. Set `sending_enabled: true` only after
Cloudflare has also verified this sending domain. Incoming routing and outgoing
domain verification are separate setup steps. An address's route is activated
separately below.

Each exact domain belongs to one tenant. Domain ownership, tenant key and
Cloudflare account identity cannot be reassigned through normal model updates.
Keep tenant keys stable and resolve them to provisioned databases through your
trusted tenant adapter. Use customer/organization IDs rather than deriving a
database filename directly from an email address.

## Create a mailbox and activate its route

Even in a single database, use an explicit tenant key and the scoped session:

```ruby
inboxes.for_tenant("organization-123") do |account|
  mailbox = account.create(
    name: "Customer support",
    address: "support@acme.example.com",
    owner_ref: "team:42",
  )
  address = account.addresses(mailbox.id).first

  provisioner = Cloudflare::Email::RoutingProvisioner.new(
    api_token: Cloudflare::Email::Credentials.management_token,
  )
  account.provision_address!(address.id,
    provisioner: provisioner,
    worker_name: "cloudflare-email-ingress-development",
  )
end
```

`owner_ref` is your application's optional stable reference to a user, site,
team or customer. The gem stores it; it does not load that record or authorize
the person using it. Authorize the organization and mailbox in your app first.

The address stays pending if provisioning fails. The provisioner upserts an
individual address rule, so you can retry setup. Run provisioning outside a
database transaction. DNS propagation and an actual inbound test are still
needed after the API succeeds.

If you already configured a route separately, record that explicitly:

```ruby
account.activate_address!(address.id, evidence: "Existing route verified in ticket 43")
```

This example assumes the same `for_tenant` block and local variables as above.
The gem does not change a zone-wide catch-all while creating a mailbox.

## Aliases, suspension and ownership

An alias is another address attached to the same mailbox:

```ruby
inboxes.for_tenant("organization-123") do |account|
  mailbox = account.mailboxes.find_by!(owner_ref: "team:42")
  alias_address = account.add_address(mailbox.id, address: "help@acme.example.com")
  # Provision alias_address exactly as you provisioned the first address.

  account.suspend(mailbox.id) # Stops new ingress and queued mailbox sends.
  account.resume(mailbox.id)
  # To suspend only one address:
  account.suspend_address(mailbox.id, alias_address.id)
end
```

Suspension is enforced by Rails; it does not delete the Cloudflare route. Mail
already accepted and stored remains available for processing and inspection.
Use `activate_address!` with new evidence to reactivate an address. Domain-wide
suspension is an administrative update of `ReceivingDomain#state` to `suspended`.

Addresses use lowercase ASCII dot-atom local parts and domains. Alias addresses
are explicit: the module does not automatically strip `+tags` or invent address
fallbacks. Reserve application-specific names such as Rebulk's `tracking` in
your mailbox-management policy before creation.

## Read incoming mail

The Worker signs the SMTP recipient. Rails verifies the whole request, resolves
the domain, enters its tenant context and stores raw mail plus a mailbox
membership in one database transaction. MIME To/Cc headers do not select the
tenant. Retries for the same raw message and exact SMTP recipient are deduplicated.

Inside your authenticated application's mailbox view/service:

```ruby
inboxes.for_tenant("organization-123") do |account|
  mailbox = account.mailboxes.find_by!(owner_ref: "team:42")
  account.messages(mailbox.id).inbox.unread.order(id: :desc).limit(25).each do |entry|
    inbound = account.inbound_email(mailbox.id, entry.id)
    subject = inbound.mail.subject
    raw_mime = inbound.raw_email.download
    # Build your authorized UI response here; sanitize rendered mail content.
  end
end
```

Perform tenant record access inside the block, rather than retaining lazy
relations or framework records for use under another tenant. Numeric record IDs
can overlap in separate tenant databases.

For a message entry you have already authorized:

```ruby
account.mark_read(mailbox.id, entry.id)
account.mark_read(mailbox.id, entry.id, read: false)
account.archive(mailbox.id, entry.id)
account.archive(mailbox.id, entry.id, archived: false)
```

These calls also belong inside the tenant block. Raw mail with a mailbox
membership is protected from ActionMailbox's normal automatic incineration.
Archive hides it from the inbox scope but retains the content. For deliberate
permanent deletion, use `account.purge_message(mailbox.id, entry.id)`; it deletes
the raw inbound record only when no other mailbox membership references it.
ActiveStorage schedules its attachment cleanup jobs. Apply your own retention,
encryption and backup policies; archive is not a retention policy.

## Send from the mailbox

Use a rendered ActionMailer message whose From and SMTP envelope sender are an
active address belonging to the mailbox. The domain must be enabled for sending.
`ReplyMailer` below is your application's mailer, not a generated gem class.

```ruby
inboxes.for_tenant("organization-123") do |account|
  mailbox = account.mailboxes.find_by!(owner_ref: "team:42")
  operation = account.prepare(mailbox.id,
    operation_key: "draft:789:revision:1",
    mail: ReplyMailer.reply(draft).message,
  )
  account.enqueue(mailbox.id, operation_key: operation.operation_key)
end
```

Authorize the send before preparation. If preparation is part of an application
transaction, enqueue only after its **outer commit**. The job queue must process
`mailers`. Do not also call `deliver_later` on the mailer.

The caller's operation key is namespaced by tenant and mailbox. Save the returned
operation key and reuse it when enqueueing a retry. Re-rendering an already
prepared operation may change MIME headers and raises a snapshot conflict.
The job serializes tenant, mailbox ID and operation key—not MIME or credentials.
It checks the current mailbox/address/domain state again before sending.

Inspect `account.outbound_messages(mailbox.id)` and each link's
`outbound_delivery` for the saved operation, provider ID and recipient outcomes.
Accepted or partial attempts are never automatically resent. Uncertain attempts
need [audited reconciliation](outbox.md#reconcile-uncertainty), available through
`account.reconcile(mailbox.id, operation_key: saved_key, **evidence)`.

For several Cloudflare accounts, configure a runtime client resolver **before
loading mailbox models**:

```ruby
Cloudflare::Email::Mailboxes.configure(
  directory_base: DirectoryRecord,
  client_resolver: ->(tenant_key, account_id) {
    Cloudflare::Email::Client.new(account_id: account_id,
      api_token: YourSecretStore.email_token(tenant_key, account_id),
      retry_ambiguous: false)
  },
)
```

`DirectoryRecord` and `YourSecretStore` are application examples. For one account,
the default resolver uses the existing gem credentials and verifies the account
matches. Cloudflare account IDs and your tenant keys are separate identities.

## Delivery events and recovery

Configure the [Cloudflare Queue subscription and token](delivery-events.md).
Use shared intake for tenant mailboxes, rather than selecting a tenant from the
event's recipient or Cloudflare account:

```ruby
Rails.application.config.x.cloudflare_email.event_domains = ["acme.example.com"]
Rails.application.config.x.cloudflare_email.event_handler = ->(event) {
  Cloudflare::Email::Mailboxes::Events.record(event)
}
```

Schedule `cloudflare:email:consume_events` to poll batches. Also schedule these
jobs regularly, starting at the beginning of each scan:

```ruby
Cloudflare::Email::Mailboxes::ReplayEventsJob.perform_later
Cloudflare::Email::Mailboxes::RecoverJob.perform_later("organization-123")
```

Schedule recovery for each provisioned organization in your own directory. Each
job processes a bounded page and enqueues its continuation. Recovery dispatches
prepared operations, repairs accepted-result callbacks and registers provider
correlation; it does not clear uncertain send claims. Domain suspension leaves
events retained for later projection.

Shared event intake commits before queue acknowledgement. After an accepted
send, the gem registers account/message/recipient correlation to the tenant's
outbox record. Events arriving first remain unmatched until replay. Tenant
projection commits before shared completion; a crash between those commits
causes safe redelivery to the tenant's deduplicating receipt ledger. Ambiguous
correlations remain unprojected.

The existing `config.x.cloudflare_email.outbox_delivery_handler` and
`outbox_recipient_handler` callbacks work here too. Keep them idempotent and on
the same tenant connection when atomicity is required. External effects cannot
be rolled back. Provider acceptance, shared storage and tenant storage are not
one transaction; this is not exactly-once delivery.

## Isolation and rollout

The scoped session API checks tenant/mailbox ownership and sender addresses.
It does not authenticate Rails users. Protect admin directory APIs, choose the
tenant through your access resolver, and authorize every mailbox operation.
Direct/unscoped ActiveRecord access is an application-level privileged interface,
particularly in shared-database mode; it is not a row-level authorization system.

For database tenancy, configure all framework storage on the tenant connection
and exclude ingress from hostname/session tenant selection. New framework jobs
capture tenant context before serialization and restore it before GlobalID
lookup. Drain existing ActionMailbox/ActiveStorage queues before enabling this
mode: previously serialized jobs without the new metadata are rejected.

The gem does not create organizations/users, verify customer domain ownership,
provide IMAP/POP, or supply a full compose/conversation inbox. The optional
[management engine](management-engine.md) supplies mailbox administration and
plain-text previews using your host's access policy. The original Rebulk document-processing
Worker contract and sender-review policy still need a separate application
migration; installing this module does not replace that live pipeline.
