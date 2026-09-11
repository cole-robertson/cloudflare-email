# SQLite mailboxes with activerecord-tenanted

Use this setup when each organization has its own SQLite database. The shared database holds receiving domains and delivery-event routing. Mailboxes, messages, and the outbox live in the organization's database.

This setup is entirely opt-in. Skip this guide for a single database: installing
the gem or running the mailbox generator does not enable database tenancy.

`activerecord-tenanted` is an optional application dependency. The gem's integration test uses version 0.8 on Rails 8.1; you do not need it for a single database or another tenant adapter.

## 1. Configure your databases

Add `gem "activerecord-tenanted", "~> 0.8.0"` to your application's Gemfile and run `bundle install`.

For example, in `config/database.yml`:

```yaml
production:
  primary:
    adapter: sqlite3
    database: storage/directory.sqlite3
    migrations_paths: db/migrate
  tenant:
    adapter: sqlite3
    tenanted: true
    database: storage/tenants/%{tenant}/db.sqlite3
    migrations_paths: db/tenant_migrate
```

Use equivalent entries for development and test. Keep tenant keys stable, such as an organization's internal identifier. Customer-supplied hostnames are not tenant authorization.

Generate the mailbox migrations in the correct directories:

```sh
bin/rails generate cloudflare:email:mailboxes \
  --directory-migrations-path=db/migrate \
  --tenant-migrations-path=db/tenant_migrate
```

Put Action Mailbox and Active Storage migrations in the tenant migration directory too. Apply the shared migrations and the tenant migrations using your application's database provisioning workflow. Keep every existing tenant's schema current before starting workers against a new release.

## 2. Load stable connection classes before the mailbox models

The optional gem models inherit from your tenant base. That base must keep the same Ruby class identity across Rails development reloads. Define it in a file you explicitly require, outside reloadable model directories. If your app already has these bases, use those same classes; do not create competing versions.

For example, `lib/email_database_records.rb`:

```ruby
class TenantRecord < ActiveRecord::Base
  self.abstract_class = true
  tenanted "tenant"
end

class DirectoryRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :primary }
end
```

Keep this file outside any paths your application configures for reloadable autoloading. Require it during application initialization after `activerecord-tenanted` has installed its Active Record support, and before the generated mailbox initializer loads the optional models. Add this inside your application class in `config/application.rb`:

```ruby
config.active_record_tenanted.connection_class = "TenantRecord"
config.active_record_tenanted.tenanted_rails_records = true

config.active_record_tenanted.tenant_resolver = ->(request) do
  if request.path == "/rails/action_mailbox/cloudflare/inbound_emails"
    nil
  else
    request.subdomain # Replace with your existing authorized tenant resolver.
  end
end

initializer "my_app.cloudflare_email_tenancy",
    after: "active_record_tenanted.active_record_base",
    before: :load_config_initializers do
  require Rails.root.join("lib/email_database_records").to_s
  require "cloudflare/email/tenancy"
  require "cloudflare/email/mailboxes/configuration"

  Cloudflare::Email::Tenancy.configure(
    base_class: TenantRecord,
    current: -> { TenantRecord.current_tenant },
    switch: ->(key, &block) {
      unless TenantRecord.tenant_exist?(key)
        raise Cloudflare::Email::Mailboxes::Unavailable,
          "tenant is not provisioned"
      end
      TenantRecord.with_tenant(key, &block)
    }
  )
  Cloudflare::Email::Mailboxes.configure(directory_base: DirectoryRecord)
end
```

Leave the generated `cloudflare_email_mailboxes.rb` initializer to require `cloudflare/email/mailboxes`. Remove any duplicate tenancy configuration from other initializers.

The ingress exception in the resolver matters: `activerecord-tenanted` normally locks a request to the tenant selected from its hostname. Email ingress must select its tenant from the verified recipient and shared domain directory, after the gem verifies the complete message signature. Returning `nil` lets that signed-recipient lookup select the correct database.

`tenanted_rails_records = true` puts Action Mailbox and Active Storage on the configured tenant connection. Include their tables in tenant migrations and configure private storage. The gem restores its tenant context for its supported email and attachment jobs. For your own jobs that serialize tenant model arguments, prepend `Cloudflare::Email::TenantJobContext` and enqueue them inside `Cloudflare::Email::Tenancy.with(key)`; ordinary host tenant context alone does not establish the gem's context.

## 3. Provision organizations separately from mailboxes

Create tenant databases in your trusted organization-provisioning workflow:

```ruby
TenantRecord.create_tenant("organization-123")
```

The switch adapter above refuses missing tenants. Receiving mail or replaying a delivery event will never create a new tenant database implicitly.

After registering and activating the organization's receiving domain, use the mailbox API within its context:

```ruby
Cloudflare::Email::Mailboxes.for_tenant("organization-123") do |inboxes|
  mailbox = inboxes.create(
    name: "Support",
    address: "support@customer.example.com",
    owner_ref: "team:42"
  )
  # Provision and activate the address before receiving or sending mail.
end
```

See the [mailbox guide](mailboxes.md) for domain activation, address provisioning, sending, and event replay. Your application still authorizes which organization, mailbox, and message each user can access.

## What is verified

The optional CI job boots a real Rails application with `activerecord-tenanted`, runs the gem's tenant migrations in two SQLite databases, and checks identical numeric IDs remain isolated. It also verifies context restoration, refusal to create unknown tenant databases, and GlobalID's missing/wrong-tenant rejection. Separate integration tests exercise mailbox ingress, sending, jobs, and delivery-event replay.

Run the library-specific smoke test locally with:

```sh
BUNDLE_GEMFILE=gemfiles/tenanted.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/tenanted.gemfile bundle exec ruby test/support/activerecord_tenanted.rb
```
