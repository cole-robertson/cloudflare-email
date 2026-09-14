# Mailbox Kit

Persistent inboxes and a management UI built on Rails Action Mailbox.
Use it when your application needs named inboxes, aliases, read/archive state,
and access control. SQLite works out of the box; database tenancy is opt-in.

Rails already stores raw email, parses it, routes it to handlers, and runs
processing jobs. Mailbox Kit adds the inbox your users interact with.

## Install

For a Rails app using another inbound provider:

```ruby
gem "mailbox-kit", "~> 0.1.0"
```

```sh
bundle install
bin/rails action_mailbox:install
bin/rails generate mailbox_kit:install
bin/rails db:migrate
```

Skip `action_mailbox:install` if Action Mailbox is already configured.

For Cloudflare, use the [Cloudflare mailbox guide](https://github.com/cole-robertson/cloudflare-email/blob/main/docs/mailboxes.md)
instead. Cloudflare Email installs Mailbox Kit automatically.

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

## More features

Use the [integration guide](docs/integration.md) for aliases, catch-all addresses,
retention, authentication, and separate tenant databases.

Your app supplies users, organizations, sender policy, and mailbox permissions.
`owner_ref` stores your reference to an application record; it does not grant access.
Inbound and outbound email can use different providers through Rails.
