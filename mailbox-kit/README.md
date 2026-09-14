# Mailbox Kit

Persistent inboxes and a management UI built on Rails Action Mailbox.
Use it when your application needs named inboxes, aliases, read/archive state,
and access control. SQLite works out of the box; database tenancy is opt-in.

Rails already stores raw email, parses it, routes it to handlers, and runs
processing jobs. Mailbox Kit adds the inbox your users interact with.

## Choose your setup

- **Cloudflare receiving or sending:** follow the [Cloudflare Rails guide](https://github.com/cole-robertson/cloudflare-email/blob/main/docs/getting-started.md).
  It includes this core; use the Cloudflare installer.
- **An existing Action Mailbox integration:** install this core and attach received
  email to inboxes. Follow the example below.
- **Only processing incoming email:** Action Mailbox alone may be enough.

Add Mailbox Kit 0.1 to your Gemfile:

```ruby
gem "mailbox-kit", "~> 0.1.0"
```

For a new Rails 7.2–8.1 application:

```sh
bundle install
bin/rails action_mailbox:install
bin/rails generate mailbox_kit:install
bin/rails db:migrate
```

Already using Cloudflare mailboxes? Follow the [upgrade guide](docs/upgrading.md)
instead of creating the tables again.

## Create an inbox in code

After configuring and verifying your provider's receiving route:

```ruby
boxes = MailboxKit::Mailboxes
domain = boxes.register_domain(domain: "in.example.com", tenant_key: "workspace")
boxes.activate_domain!(domain.id, evidence: "Receiving route verified")

boxes.for_tenant("workspace") do |session|
  inbox = session.create(name: "Support", address: "support@in.example.com")
  session.activate_address!(inbox.addresses.first.id, evidence: "Receiving route verified")
end
```

`workspace` scopes inboxes within the default database. It does not enable separate
tenant databases. Creating an address does not configure DNS or authorize sending.

## Connect received email

If your authenticated integration already has an Action Mailbox record:

```ruby
MailboxKit::Mailboxes.for_tenant(trusted_tenant_key) do |session|
  session.attach(recipient: verified_envelope_recipient,
                 inbound_email_id: inbound_email.id)
end
```

Authorize the record in the application first. Use the provider's verified
envelope recipient, not an untrusted email header. Keep your ordinary
`ApplicationMailbox` handlers: attachment does not process the email again.
The Cloudflare inbox ingress already performs this integration for you.

## Read and manage

```ruby
MailboxKit::Mailboxes.for_tenant("workspace") do |session|
  unread = session.messages(inbox_id).inbox.unread
  session.mark_read(inbox_id, message_id)
  session.archive(inbox_id, message_id)
end
```

The optional management engine provides a server-rendered UI with no frontend
build. Your application supplies authentication and authorizes each action;
access is denied until configured. See [management setup](docs/integration.md#management-interface).

## The split

Mailbox Kit works without Cloudflare. Cloudflare Email depends on this core and
installs it automatically; applications using both APIs may list both gems in
their Gemfile to make their direct dependencies explicit. Either declaration
installs the same packages. Inboxes, database tenancy, and the management UI still
require explicit setup. Installing the gem does not enable them.

The core has no runtime gem dependencies and does not load Rails or Active Record
for plain Ruby consumers. Rails applications supply their framework dependencies;
the core registers Rails integration hooks when Rails is present.

| Layer | Owns |
| --- | --- |
| Rails | Raw MIME, Active Storage, parsing, routing, processing jobs/status, cleanup policy, Action Mailer |
| Mailbox Kit | Inbox identities, addresses/aliases, memberships, read/archive state, selective retention, optional tenant context, management UI |
| Cloudflare | Request verification, authoritative envelope metadata, Worker retries/storage, sending, delivery feedback, provisioning |
| Your app | Users/organizations/sites, ownership lifecycle, authorization, sender acceptance, business effects |

Inbound and outbound can use different providers through Rails. The core does
not send email or supply a universal outbound adapter registry. `owner_ref` is an
application-managed reference; it is not an automatic `has_mailbox` association
or permission grant.

Inbox-associated messages survive Rails' automatic incineration. For retaining
all inbound messages, Rails already offers `config.action_mailbox.incinerate = false`.
Raw storage and processing remain Rails responsibilities.

See the [integration guide](docs/integration.md) for aliases, catch-all addresses,
verified source ingestion, duplicates, retention, authorization and optional
database tenancy. See [upgrading](docs/upgrading.md) for existing installations.
