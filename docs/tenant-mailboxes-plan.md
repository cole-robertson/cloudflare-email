# Tenant-aware mailbox layer — implementation proposal

Status: original design record. The reusable mailbox module and tenant adapter
are implemented on the feature branch; see [mailboxes](mailboxes.md) and
[tenant setup](activerecord-tenanted.md) for the actual API. Rebulk application
migration and live customer rollout remain separate work. Based on the gem's merged 0.2
code and Rebulk/rebulk-system main at
`17ffafccb69968dae022acdbb4620b84c65bedfb`.

## Product goal

Let a Rails application create, suspend and manage named mailboxes for its
organizations, sites or users. Support organization subdomains such as
`houston@venezia.rebulk.com`. Reuse the gem's transport, outbox and receipts;
do not create another delivery ledger. SQLite remains the default integration
target, including separate SQLite databases with `activerecord-tenanted`.

## Rebulk already has the foundations

- `Organization` is shared and carries `email_subdomain`.
- `TenantRecord` uses `activerecord-tenanted` and requires a tenant context.
- Sites have per-organization email local parts. `tracking@<org>.rebulk.com`
  is an existing reserved organization-level destination.
- `Customer` is a buyer within an organization, not the tenant root. A customer
  mailbox can belong to that record without creating another tenant database.
- ActiveStorage is tenant-specific. Mail must resolve its tenant before blob
  access, persistence or job deserialization that needs tenant records.
- `InboundEmail` records document-processing outcomes inside the tenant.
  `CommunicationMessage` is a shared, encrypted cross-channel operational view.
  Preserve these product roles instead of replacing them with duplicate models.
- Existing ingest has its own Worker contract, sender authentication and
  authorization, raw archive and document processing. It is not currently the
  gem's ActionMailbox pipeline. Its policy cannot be discarded during migration.
- `OrganizationEmailDomain` supports sign-in auto-join. Receiving-domain
  ownership must be separate; creating a receiving domain must never grant users
  membership or change login policy.

## Database and routing boundary

Keep a minimal shared receiving-domain directory: exact canonical domain,
immutable tenant identity, tenant connection key, lifecycle state and provisioning
evidence. Enforce domain ownership with a database uniqueness constraint. Never
construct a SQLite path from an arbitrary recipient string or request parameter.

Keep mailbox definitions, address aliases, message memberships, outbox records
and tenant receipts in the tenant database. Support an application-selected
ActiveRecord base class so every related gem model uses the intended connection.
Merely wrapping today's hardcoded `ActiveRecord::Base` models in `with_tenant`
does not establish that connection contract.

The ingress sequence must be:

1. Bound the body and verify the complete Worker signature and envelope.
2. Resolve the exact signed recipient domain in the shared active directory.
3. Enter the mapped tenant context, without creating a tenant implicitly.
4. Resolve the registered active mailbox/alias inside that tenant.
5. Persist raw mail and mailbox membership idempotently, then schedule processing.
6. Restore tenant context even when processing raises.

No MIME To/Cc, browser session fallback, sender domain or guessed organization
slug may select the receiving tenant. Unknown/suspended domains and addresses
must have explicit rejection or restricted quarantine outcomes, with no fallback
to an arbitrary tenant/mailbox. Directory changes and mailbox suspension must
also be checked when deferred work resumes; never silently reassign old mail.

## Optional mailbox module

Add explicit opt-in loading and a generator. The initial contract should cover:

- Tenant/domain registration and verified provisioning state.
- Mailbox creation, aliases, suspension and lookup by registered address.
- Application ownership links for user/site/customer mailboxes, checked within
  the resolved tenant; authenticated actor authorization stays in the host app.
- Incoming message membership and deduplication without another copy of MIME.
- Outgoing preparation through an active mailbox with an allowed From address,
  linked to the existing outbox. A customer cannot select another tenant's
  sender merely because both share the same Cloudflare account token.
- An explicit tenant context adapter and connection-class configuration;
  `activerecord-tenanted` is an optional integration, not a plain-Ruby dependency.

Do not claim a finished inbox UI, IMAP/POP service, thread model, AI workflow,
search engine or membership system. Rebulk supplies those product decisions.
Document local-part case policy, reserved names and alias behavior before schema
implementation; normalization must agree across directory, mailbox and send APIs.

## Jobs, events and cross-database commits

Jobs carry stable tenant and operation/mailbox identities. Establish tenant
context before loading records. Never rely on a previous request's `Current`
state, a naked numeric record ID or a Cloudflare account ID as a tenant key.
Cloudflare account identity and application tenant identity are different.

Queue events arrive without a Rails tenant context and may precede a saved send
response. Use a shared durable receipt intake and a provider correlation
directory populated by tenant outbox results. Retain unmatched events and retry
when correlation becomes available; do not infer tenant ownership solely from
the recipient's external domain. Ambiguous mappings remain unprojected.

Delivery from shared intake to tenant projection is at least once. A tenant
receipt deduplicates it. Mark shared processing complete only after tenant commit;
crashes between commits cause safe replay. Writes to the shared directory,
tenant SQLite and job queue are not one transaction. Recovery must cover each
gap without allowing another send or prematurely acknowledging an event.

## Customer subdomains and Cloudflare

An organization may use a Rebulk-owned subdomain or, later, an explicitly verified
customer-owned domain. Track receive readiness and send-domain verification
separately. A Rails database record or wildcard DNS entry alone does not enable
Cloudflare email routing or sending.

Prefer explicit address rules for the first supported provisioner. Reconcile
desired state with Cloudflare and retain failures for retry rather than marking
a mailbox active before its route is ready. Multiple tenants may share a Worker
and ingress secret within one application/environment; tenant routing stays in
Rails. Separate Cloudflare accounts require account-aware credentials/jobs.

The current catch-all task operates at zone scope. Do not alter the Rebulk apex
catch-all or promise automatic subdomain catch-alls as part of mailbox creation.
Verify provider support and limits for the exact subdomain topology before a
live rollout. Custom domains need ownership verification and safe offboarding.

## Implementation slices and acceptance checks

1. **Tenant foundation:** configurable model connections, tenant-aware job
   wrappers and migrations in the tenant migration path. Test two real SQLite
   tenant databases with overlapping IDs, missing context, retries and cleanup.
2. **Mailbox registry:** shared domain mapping plus tenant mailboxes/aliases,
   lifecycle and ownership APIs. Test exact matching, uniqueness races,
   suspension, reserved addresses and isolation for lookup and sending.
3. **Tenant ingress:** authenticated envelope resolution before ActionMailbox
   storage. Test Bcc routing, raw bytes, duplicate delivery, unknown destinations,
   tenant-specific blob access and processing jobs after process restart.
4. **Outbound/event integration:** reuse saved MIME/claims, enforce mailbox sender
   identity, add durable shared-to-tenant event dispatch and repair scans. Test
   event-before-response, duplicate receipts and crashes at each commit boundary.
5. **Rebulk adoption:** map existing org/site addresses, preserve tracking and
   sender-review policies, link existing communication/ingest records, and add
   mailbox management through Rebulk's access resolver. Start behind a feature
   flag on an isolated development address; keep current production routes intact.
6. **Provisioning and live verification:** test domain/route setup with bounded
   retries, then a real send/reply/attachment/event flow for two test tenants.
   Verify the deployed revision and preserve a dated report before customer rollout.

Required regressions include existing plain-Ruby, single-database SQLite and
PostgreSQL behavior. Do not call the integration complete merely because a
single-tenant send works. Existing Rebulk sender-authentication metadata must
remain authenticated through the new Worker contract before its old ingress
can be retired; the gem's v2 envelope alone does not supply that policy evidence.
