# Mailbox Kit

Persistent inboxes for Rails, independent of your email provider. Create mailboxes
and aliases, route incoming recipients, retain messages, and mount a small server
rendered management interface. SQLite works; separate tenant databases are opt-in.

This package is maintained alongside `cloudflare-email` so changes to the core and
its first integration can be tested together. It is not yet published. In this
checkout use `gem "mailbox-kit", path: "mailbox-kit"`. Once released, applications
can use `gem "mailbox-kit", "~> 0.1"`.

## What belongs where?

| Layer | Responsibility |
| --- | --- |
| Mailbox Kit | Mailboxes, addresses, recipient lookup, message membership, read/archive/purge, retention, tenant context, management UI |
| Rails | ActionMailbox raw MIME and ActiveStorage attachments; jobs; ActionMailer |
| Provider integration | Verify incoming requests and envelope recipients, deliver outgoing messages, authenticate delivery feedback, configure DNS/routes |
| Your application | Users, organizations, sites, permissions, sender acceptance and business workflows |

Mailbox Kit does not require Cloudflare, configure DNS, or send messages by itself.
`cloudflare-email` supplies its existing Worker ingress, sending/outbox, feedback,
and provisioning integration. Other providers can call the core receiving APIs;
this release does not claim a tested SES, Postmark, or generic outbound adapter.
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

## Receive and retain messages

Your ingress adapter must authenticate the request and extract the actual SMTP
envelope recipient before invoking the core. Do not route on an untrusted MIME
`To` header or a customer-supplied tenant key.

```ruby
MailboxKit::Mailboxes.receive(recipient: verified_envelope_recipient) do |destination|
  # Perform application acceptance checks here, inside the resolved tenant.
  ActionMailbox::InboundEmail.create_and_extract_message_id!(raw_mime)
end
```

The core resolves an active domain and address, selects the tenant, and records
the mailbox membership in the same transaction as your persistence block. Your
transport adapter remains responsible for authenticating and deduplicating its
deliveries and retrying failed requests. ActionMailbox routing still needs an
`ApplicationMailbox` route and an application handler.

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

Mailbox membership retains the ActionMailbox raw source beyond its normal
incineration window. `purge_message` explicitly removes membership and deletes raw
mail only when no mailbox memberships remain. ActionMailbox, ActiveStorage and
mailbox records must share a connection for atomic persistence and purge.

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
