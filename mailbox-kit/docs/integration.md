# Integration guide

Persistent inboxes on top of Action Mailbox, independent of your email provider. Rails
already stores and parses email, routes it to processing handlers, and provides
configurable retention. Mailbox Kit adds inbox identities, addresses/aliases,
membership, read/archive state, scoped access and a server-rendered management UI.
SQLite works; separate tenant databases are opt-in.

This package is maintained alongside `cloudflare-email` so changes to the core and
its first integration can be tested together. It is not yet published. In this
checkout use `gem "mailbox-kit", path: "mailbox-kit"`. Once released, applications
can use `gem "mailbox-kit", "~> 0.1"`.

## What belongs where?

| Layer | Responsibility |
| --- | --- |
| Mailbox Kit | Inbox identities, addresses, recipient lookup, membership, read/archive/purge, selective retention, tenant context, management UI |
| Rails | InboundEmail records, original MIME/ActiveStorage, parsing, processing callbacks/status, routing jobs, configurable retention, and ActionMailer |
| Provider integration | Verify incoming requests and envelope recipients, deliver outgoing messages, authenticate delivery feedback, configure DNS/routes |
| Your application | Users, organizations, sites, permissions, sender acceptance and business workflows |

Mailbox Kit does not require Cloudflare, configure DNS, or send messages by itself.
`cloudflare-email` supplies its existing Worker ingress, sending/outbox, feedback,
and provisioning integration. Other providers can call the core receiving APIs;
this release does not claim complete SES, Postmark, or generic outbound adapters.
The tests exercise Rails' stock Postmark HTTP ingress followed by explicit kit
attachment in one database; provider setup, dynamic envelope authorization and
provider outage behavior are separate integration responsibilities.
Inbound and outbound need not use the same service. A mailbox has no `provider`
attribute: receiving through one provider does not authorize sending through it.

## Create an inbox

Use Rails 7.2–8.1 with Active Record. Install ActionMailbox when you want its raw
message storage and the message-reading UI:

```sh
bin/rails action_mailbox:install
bin/rails generate mailbox_kit:install
bin/rails db:migrate
```

The generator adds an initializer requiring `mailbox_kit/mailboxes`. Register a
domain from trusted setup code after configuring your receiving provider:

```ruby
boxes = MailboxKit::Mailboxes
domain = boxes.register_domain(domain: "in.example.com", tenant_key: "workspace")
boxes.activate_domain!(domain.id, evidence: "Receiving route verified by an end-to-end test")

boxes.for_tenant("workspace") do |session|
  inbox = session.create(
    name: "Support", address: "support@in.example.com", owner_ref: "team:stable-uuid"
  )
  session.activate_address!(inbox.addresses.first.id, evidence: "Provider route verified")
  # Aliases belong to the same inbox; each starts pending until activated.
  session.add_address(inbox.id, address: "help@in.example.com")
end
```

`workspace` is an explicit scope in a single database; it does not turn on database
tenancy. Domain/address activation records evidence supplied by your trusted
application. It does not verify DNS or grant permission to send from that address.

`owner_ref` is currently an application-managed reference, not a foreign key or an
authorization grant. Use stable identities, rather than reusable numeric IDs.
Automatic `has_mailbox` owner bindings and deletion reconciliation are a separate
follow-up; this extraction does not introduce a callback that could silently
reassign an old address to a new owner.

## Reuse Action Mailbox

For a receive-and-process application, Action Mailbox alone may be enough. It
already supports dynamic handlers through regex/callable routes, processing
callbacks, test helpers, and the development conductor at
`/rails/conductor/action_mailbox/inbound_emails`. The kit does not replace those.
Rails' `delivered` status means an inbound handler finished processing; read and
archive state belong to the kit's inbox membership instead.

If an existing Rails ingress has already stored an email, attach that record:

```ruby
MailboxKit::Mailboxes.for_tenant(trusted_tenant_key) do |session|
  membership = session.attach(
    recipient: verified_envelope_recipient,
    inbound_email_id: inbound_email.id
  )
end
```

The caller must authorize the inbound ID and select its tenant before loading
records. Do not pass an ID from another tenant or accept an unscoped ID from a
customer. Attachment checks active address ownership, looks up the Rails record
in the current connection, and rejects existing membership in another tenant.
It is idempotent for the inbox/email pair and does not enqueue processing again.
Aliases into the same inbox share a membership, retaining the first recipient.

Use Rails' normal `ApplicationMailbox` routing and processing callbacks. One
handler can dynamically resolve many organizations/sites; no class per inbox is
needed. Default Rails routes match message headers and choose the first handler;
they do not establish trusted tenant entitlement or automatically fan out into
every recipient's inbox. Select a tenant before initial storage if raw mail lives
in separate tenant databases. Attaching later cannot relocate that original row.

## Receive source through a verified integration

Your ingress adapter must authenticate the request and extract the actual SMTP
envelope recipient before invoking the core. Do not route on an untrusted MIME
`To` header or a customer-supplied tenant key.

```ruby
inbound_email = MailboxKit::Mailboxes.receive(
  recipient: verified_envelope_recipient,
  source: raw_mime
)
```

The core resolves an active domain and address, selects the tenant, and records
the mailbox membership in the same database transaction as Rails persistence.
It calls Rails' creation API and returns the existing record on duplicate source.
Identical source within one tenant can belong to multiple inboxes without creating
another raw email or routing job. Default source identity includes the tenant
scope and uses a stable fallback for missing Message-ID; identical bytes in a
different tenant do not suppress that tenant's processing. MIME is not rewritten.
The adapter remains responsible for authentication, authoritative envelope
recipients, delivery-specific identity where necessary, and retrying failed
requests. ActionMailbox still owns processing and its `ApplicationMailbox` routes.

For application checks before persistence, the existing block form remains:

```ruby
require "mailbox_kit/inbound_email"
MailboxKit::Mailboxes.receive(recipient: verified_envelope_recipient) do |destination|
  MyAcceptancePolicy.check!(destination) # Application policy; raise to reject.
  MailboxKit::InboundEmail.persist(source: raw_mime).record
end
```

Blocks must return the existing Rails record on duplicates if membership should
be attached. Rails' bare `create_and_extract_message_id!` returns `nil` for a
duplicate, so using it directly in that block can omit a second inbox membership.
Returning `nil` intentionally skips membership, preserving the older block API.
Neither a database transaction nor source deduplication guarantees exactly-once
business effects, external blob cleanup on rollback, or recovery of lost jobs.

With Cloudflare, the adapter preserves its existing authenticated envelope and
metadata-based delivery identity, then uses the same Rails persistence bridge:

```ruby
verified = Cloudflare::Email::Ingress.verify(
  secret: ingress_secret, headers: request.headers, body: request.body
)
# Handle non-:ok verification results before accessing the verified message.
verified.message.receive_into_mailbox! if verified.status == :ok
```

The shipped Cloudflare ingress controller already does this, including HTTP error
handling and size limits. Installing the core does not add another HTTP endpoint
or SMTP server. `persist_action_mailbox!` remains available for applications that
only need Rails storage; its existing return convention is new record or `nil`
on duplicate. The new inbox bridge can repair membership on duplicate delivery
without rerouting the email or replacing stored authentication metadata.

For an application with its own persistence, use
`with_recipient(recipient:) { |destination| ... }`; it performs lookup and tenant
selection without creating a message membership. It can run without ActionMailbox.

An explicit pending/suspended address reserves its name: it never falls through
to another inbox's catch-all. Unknown addresses are unavailable unless you
explicitly enable a verified catch-all address with `session.enable_catch_all`.

```ruby
MailboxKit::Mailboxes.for_tenant("workspace") do |session|
  messages = session.messages(inbox_id).inbox.unread
  session.mark_read(inbox_id, message_id)
  session.archive(inbox_id, message_id)
  session.suspend(inbox_id) # Reversible; reserves existing addresses.
end
```

## Retention is a Rails policy

To retain all inbound mail, Rails already provides:

```ruby
config.action_mailbox.incinerate = false
```

Or configure its automatic cleanup interval with
`config.action_mailbox.incinerate_after = 90.days`. Disabling scheduling does not
cancel incineration jobs already queued. Rails normally schedules processed mail
for cleanup after 30 days; pending mail is not processed mail.

For apps that mix inboxes and transient email handlers, the kit adds a narrow
membership guard through Rails' `action_mailbox_inbound_email` load hook: mail
associated with an inbox survives normal incineration, while unassociated mail
uses Rails' policy. `purge_message` explicitly removes membership and deletes raw
mail only when no mailbox memberships remain. Attach, purge and this guard lock
the same inbound row. Direct application deletion and external storage expiration
remain the application's responsibility. ActionMailbox, ActiveStorage and mailbox
records must share a connection for the transactional membership operations.

## Management interface

Require the optional engine in `config/application.rb`, before Rails initializes:

```ruby
require "mailbox_kit/management"
```

Mount it in `config/routes.rb`:

```ruby
mount MailboxKit::Management::Engine => "/mailboxes"
```

Configure `MailboxKit::Management.configure { |c| c.adapter = ->(controller) {
MailboxAccess.new(controller) } }` in an initializer. `MailboxAccess` subclasses
`MailboxKit::Management::Adapter` and supplies:

- `authenticate!`: authenticate using the host application's session.
- `tenant_key`: select a trusted scope for that principal.
- `mailboxes(session)`: return only mailboxes the principal can access.
- `allowed?(action, mailbox = nil)`: authorize each operation.
- `domains(session)`: return domains the principal may use.

All defaults deny access. The engine intersects your relation with its tenant
scope and checks permissions again for each action. Override `create_mailbox` and
`add_address` to attach your ownership policy. Ownership alone never grants access.
The UI needs no React, Inertia, or frontend build. It shows safe text previews;
remote images and arbitrary email HTML are not rendered.

## Optional database tenancy

Before requiring mailbox models, configure your application's connection switch:

```ruby
require "mailbox_kit/tenancy"
MailboxKit::Tenancy.configure(
  base_class: TenantRecord,
  switch: ->(key, &block) { TenantRecord.with_tenant(key, &block) },
  current: -> { TenantRecord.current_tenant }
)
require "mailbox_kit/mailboxes/configuration"
MailboxKit::Mailboxes.configure(directory_base: SharedRecord)
require "mailbox_kit/mailboxes"
```

Those host methods are examples; adapt them to your tenancy library. Run directory
migrations on the shared database and mailbox migrations on each tenant database
using the generator's `--directory-migrations-path` and `--tenant-migrations-path`.
Never choose the tenant from request parameters. Rails framework jobs preserve the
explicit context; your own tenant jobs can `prepend MailboxKit::TenantJobContext`
after requiring `mailbox_kit/tenant_job_context`.

## Existing Cloudflare Email applications

Keep your existing requires, initializer, migrations, Worker and mounted engine.
Updating the Cloudflare gem brings in this core as a dependency. Public Cloudflare
constants resolve to the same core models; tables, IDs and tenant job payload keys
are retained. The `cloudflare_email_` table prefix is intentionally unchanged.
Do **not** run `mailbox_kit:install` over an existing Cloudflare mailbox schema.

For a fresh Cloudflare application, continue using the Cloudflare mailbox generator,
which also installs its outbox and event tables. A core-only installation should
not run both installers; adding Cloudflare outbound later needs its additional
tables and explicit sending-account/domain configuration. The receiving-only core
does not automatically become a Cloudflare sending account when the adapter loads.

## Sending from customer subdomains

Cloudflare onboards each sending domain/subdomain separately. Parent-domain
verification and wildcard receiving do not authorize arbitrary From subdomains.
Use an explicitly verified sending domain and, where useful, a customer-specific
inbound Reply-To. See [Cloudflare's subdomain rules](https://developers.cloudflare.com/email-service/configuration/subdomains/).

## Development and release

From the repository root, `bundle exec rake test` exercises both the compatibility
API and standalone core. `bundle exec ruby script/verify_package.rb` builds both
archives, installs a Rails-free consumer, and tests the packaged Rails integrations.
Publish `mailbox-kit` before releasing a Cloudflare version that depends on it.
