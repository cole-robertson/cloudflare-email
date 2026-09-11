# Optional mailbox management engine

The management engine is a small, server-rendered Rails interface for the
[managed mailbox APIs](mailboxes.md). It works with ordinary Rails apps and with
apps using Inertia, React, Turbo or another frontend. No JavaScript, Node build,
asset pipeline or frontend package is required for the engine.

This feature is currently unreleased. It is not included in RubyGems 0.2.0.

## What you get

- Mailbox lists, names, creation and aliases on allowed receiving domains.
- Address setup status and mailbox suspension/resumption.
- A paginated list of received messages and an escaped plain-text preview.
- Optional read/unread and archive/unarchive controls.
- Ordinary CSRF-protected forms, mobile layouts and bundled CSS.

Your app supplies login, permissions, domain entitlements and any organization
mapping. The engine does not create users, claim domains, edit DNS, provision
Cloudflare routes, send mail, or permanently delete records. The default creation
hooks create pending addresses. Your administrator or existing provisioning code
completes routing and activation through the same Ruby APIs.

The viewer never renders sender HTML, loads remote images, or provides raw MIME
or attachment downloads. It shows attachment names and up to 100,000 plain-text
characters. Compose, conversations, AI workflows and product search belong in
your application.

## Install and mount

First install the managed mailbox tables and enable the module using
[the mailbox setup guide](mailboxes.md). SQLite works; database tenancy remains
off unless your app configures it explicitly.

Require the engine **before Rails initializes**, after Bundler loads the gem:

```ruby
# config/application.rb, after Bundler.require(*Rails.groups)
require "cloudflare/email/management"
```

Configure a host adapter in an initializer:

```ruby
# config/initializers/cloudflare_email_management.rb
Cloudflare::Email::Management.configure do |config|
  # Resolve the class when handling the request, so Rails reloading works.
  config.adapter = ->(controller) { EmailManagementAccess.new(controller) }
  config.back_path = ->(controller) { controller.main_app.root_path }
end
```

Mount it wherever it fits your application:

```ruby
# config/routes.rb
mount Cloudflare::Email::Management::Engine => "/email-management",
  as: :email_management
```

Installing the gem does not expose this interface automatically. Without a
configured adapter and enabled mailbox module the mounted interface returns 503.
The base adapter grants no access. Its public stylesheet endpoint serves only
the bundled CSS.

## Connect your authentication and ownership

Here is a single-database example using Rails' generated authentication convention
(`Session`, `Current.session`, and a signed `session_id` cookie). Match the cookie
and session lookup to your app; the agentic inbox example uses `session_token`.
Use the host authentication system's expiry, revocation and access policy.

```ruby
# app/services/email_management_access.rb
class EmailManagementAccess < Cloudflare::Email::Management::Adapter
  ACTIONS = %i[index show create add_address suspend resume
    show_message mark_read archive].freeze

  def authenticate!
    Current.session = Session.find_by(
      id: controller.request.cookie_jar.signed[:session_id]
    )
    @user = Current.user
    return true if @user

    controller.redirect_to controller.main_app.new_session_path
    false
  end

  def tenant_key = "application"
  def owner_ref = "User:#{@user.id}"

  def mailboxes(session)
    session.mailboxes.where(owner_ref: owner_ref)
  end

  def allowed?(action, mailbox = nil)
    @user.present? && ACTIONS.include?(action) &&
      (mailbox.nil? || mailbox.owner_ref == owner_ref)
  end

  def domains(_session)
    ["in.example.com"] # Only domains this user is entitled to use.
  end

  def create_mailbox(session, name:, address:)
    session.create(name: name, address: address, owner_ref: owner_ref)
  end
end
```

For Devise, the authentication hook can use your configured Warden scope instead
of the cookie lookup, for example
`@user = controller.request.env["warden"]&.authenticate(scope: :user)`.
The engine inherits from `ActionController::Base`; host `ApplicationController`
callbacks and methods are not inherited. Make authentication explicit in the
adapter and return exactly `true` on success, or redirect to the host's login.

The directory must already contain the active receiving domain assigned to the
same registry key. The engine intersects `domains` with that directory and
intersects the host mailbox relation with the current gem tenant. Parameters
cannot select an owner or tenant.

Do not return every domain merely because it exists in the database. A customer
app should apply organization entitlement, reserved-name and signup policies.
For separate tenant databases, return a trusted host-resolved key from
`tenant_key` and configure the existing gem tenancy adapter and framework
connections before mailbox models load.

## Customize behavior without forking the pages

The adapter has these hooks:

| Hook | Contract |
| --- | --- |
| `authenticate!` | Authenticate the request; return exactly true or redirect/deny. |
| `tenant_key` | Trusted registry key; never use an unchecked request parameter. |
| `mailboxes(session)` | ActiveRecord relation containing mailboxes accessible to this principal. |
| `allowed?(action, mailbox = nil)` | Return exactly true to permit an action. |
| `domains(session)` | Array of domain strings permitted for this principal. |
| `create_mailbox(session, name:, address:)` | Return the created gem mailbox, visible in the host's scope. |
| `add_address(session, mailbox, address:)` | Add an address through your existing app provisioning service if needed. |

All hooks run inside the resolved mailbox context. Creation also runs in a
database transaction; a returned mailbox outside the host scope rolls back.
Keep network work out of creation hooks and enqueue provisioning after commit.
The default alias hook calls `session.add_address`.

Return false for `:create` or lifecycle actions to provide a restricted dashboard.
Use `:show_message` to control message access independently of metadata. Deny
`:mark_read` and `:archive` when the host product already owns a different
conversation-level read/folder model. Hidden controls also reject direct requests.

An application with its own mailbox record can override creation and alias hooks
to call that application's service and return the linked gem model. The agentic
inbox example does this: both UIs and automatic account provisioning share one
service, so engine-created mailboxes also appear in its full inbox.

## Inertia, React and Turbo applications

Use a normal HTML link or full-page navigation to the mount. For example:

```jsx
<a href="/email-management">Manage mailboxes</a>
```

The engine returns HTML, not Inertia responses. Its separate layout keeps host
frontend dependencies out of the gem. The optional `back_path` callback returns
a local absolute path for a Back to app link. Programmatic provisioning continues
to work whether this engine is mounted or not.

## Operational behavior

Suspension preserves mailbox records and retained mail while disabling mailbox
sending/receiving. Resuming does not activate pending addresses or repair DNS.
Read/archive state belongs to the gem mailbox memberships and does not implicitly
rewrite host conversation records.

Private pages use no-store caching, a restrictive CSP and a same-origin referrer
policy. Forms check both Rails CSRF tokens and origins. Serve the host over HTTPS,
configure trusted proxy headers correctly, and keep its session cookies secure.
Do not disable CSRF to work around a proxy configuration issue.

Verification includes real Rails sessions, owner/tenant scoping, all operation
permissions, CSRF/origin checks, rollback, escaped previews, retained raw source,
and eager-loading a core-only app without exposing the engine. The example also
tests desktop/mobile Chromium and JavaScript-disabled forms with synthetic mail.
