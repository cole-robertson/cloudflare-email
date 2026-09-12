# Use your existing inbound email pipeline

This integration API is unreleased and is not included in gem version 0.2.0.

You can adopt mailbox registration without replacing your Worker, document processing, sender review, or archive. Use the gem to authenticate the request and resolve an accepted address, then keep your application's policy and processing.

A useful starting point is one mailbox per site: an organization owns a receiving domain, a site owns a mailbox, and that mailbox can have several accepted addresses. This is an application convention, not a requirement of the gem. Database tenancy is optional; a single SQLite database works too.

## Register addresses before accepting mail

Follow [mailbox setup](mailboxes.md) to register and activate the receiving domain and accepted addresses. With existing catch-all Worker routing, address creation can be a database operation once an administrator has confirmed that routing covers the exact domain. Registering a domain does not create DNS records or extend wildcard coverage.

Use the same provisioning service from organization/site onboarding and from the management UI. Keep a stable site reference in the mailbox's `owner_ref`; keep site permissions, slug changes, document workflows, and sender allowlists in your app. Treat a rename as an explicit alias/lifecycle decision so old addresses are not accidentally lost.

For separate organization databases, configure [the SQLite tenant adapter](activerecord-tenanted.md) before loading mailbox models. The shared directory resolves the signed recipient to a tenant. Action Mailbox, Active Storage, and the gem's mailbox records must all use that tenant's connection.

## Verify a custom endpoint before writing anything

`Cloudflare::Email::Ingress.verify` is usable outside the bundled controller. It accepts a String or IO body, bounds the raw body size, and returns an immutable result. Successful verification exposes the exact binary body and authenticated envelope; rejected requests expose no verified message.

The following controller is a starting point for a host with registered mailboxes:

```ruby
require "cloudflare/email/ingress"

class InboundEmailsController < ActionController::API
  def create
    result = Cloudflare::Email::Ingress.verify(
      secret: Rails.application.credentials.dig(:cloudflare, :ingress_secret),
      headers: request.headers,
      body: request.body,
      content_length: request.content_length,
      max_email_bytes: 25 * 1024 * 1024
    )

    case result.status
    when :too_large
      return head :payload_too_large
    when :bad_signature, :stale
      return head :unauthorized
    end

    verified = result.message

    Cloudflare::Email::Mailboxes.receive(
      recipient: verified.envelope.fetch("to")
    ) do |destination|
      # This block runs in the recipient's tenant. Apply your sender/review
      # policy here, before persistence schedules Action Mailbox routing.
      # Your policy may raise a host error or return nil instead of persisting.
      # destination.owner_ref identifies your site/team; validate it using
      # your application's policy in this tenant context.
      verified.persist_action_mailbox!
    end

    head :ok
  rescue Cloudflare::Email::Mailboxes::Unavailable
    head :unprocessable_entity
  end
end
```

Mount this controller at your own route and point your existing Worker there. The host owns response codes and retry policy. If your policy returns nil and you acknowledge the request, you are accepting responsibility for that email: persist a durable review record or deliberately discard it according to your application's policy. A successful verification alone does not queue processing or create a mailbox.

Do not use the MIME `To` header or an unauthenticated URL subdomain to select storage. `verified.envelope.fetch("to")` is the signed SMTP recipient. `Mailboxes.receive` checks that its domain, mailbox, and accepted address are active before entering the persistence block.

`persist_action_mailbox!` stores the verified raw bytes and metadata in Action Mailbox. The receiving block adds mailbox membership in the same tenant transaction. Rails schedules normal routing after the transaction commits. Apply policies that must stop processing before calling persistence; a check performed after receiving returns can be too late.

For an application that owns a different raw-email store, use `verified.body`, `verified.envelope`, `verified.provider_metadata`, `verified.message_checksum`, and `verified.storage_metadata` with your own persistence/transaction system. `Mailboxes.receive` specifically expects an Action Mailbox inbound email record (or nil) from its block; do not pass an unrelated processing record. The gem does not choose your archive retention, held-message model, or document queue.

## Persist the email and link your business record

Email persistence remains part of the gem's supported path. Action Mailbox stores
the raw MIME using Active Storage, the verifier saves authenticated metadata, and
`Mailboxes.receive` adds the inbox membership. Your processing/review record can
refer to that email rather than storing a second copy of its raw content:

```ruby
Cloudflare::Email::Mailboxes.receive(
  recipient: verified.envelope.fetch("to")
) do |destination|
  # Validate owner_ref and sender policy here, before any routing is scheduled.
  inbound = verified.persist_action_mailbox!
  if inbound
    # Example host model, on the SAME tenant connection as the gem records.
    EmailIntake.create!(
      inbound_email_id: inbound.id,
      mailbox_id: destination.mailbox_id,
      owner_ref: destination.owner_ref
    )
  end
  inbound # Return the ActionMailbox record; duplicate deliveries return nil.
end
```

The database writes commit together. A host failure rolls back the new email,
membership and host link and prevents the routing job from being enqueued. This
does not make an R2 archive, another database, or external API calls transactional.
Host exceptions propagate; only unavailable registry destinations are translated
to `Mailboxes::Unavailable`. Existing blocks without a destination argument still
work.

Persisting through ActionMailbox schedules its normal routing after commit. Put
your processing in that route or a deliberately coordinated job pipeline. If an
email must be held, implement a routing policy that cannot process it before
approval; storing it is not itself a review gate. A routing job failure also needs
normal job retry/recovery. Receipt deduplication does not make every downstream
business side effect idempotent.

Managed mailbox membership protects raw email from ActionMailbox's normal
automatic incineration. Archiving a mailbox message keeps its content; deliberate
purging can remove it once no other membership references the email. Raw email
saved without membership follows the normal ActionMailbox lifecycle. Keep host
references, backup and R2 retention consistent with your chosen deletion policy.
Multi-tenancy remains opt-in.

## Resolve an address with your own persistence

If your application already owns its raw-email store, use the standalone API:

```ruby
Cloudflare::Email::Mailboxes.with_recipient(
  recipient: verified.envelope.fetch("to")
) do |destination|
  # Example host-owned persistence service; it must commit durably before ACK.
  ExistingEmailStore.save!(
    tenant_key: destination.tenant_key,
    mailbox_id: destination.mailbox_id,
    recipient: destination.recipient,
    raw: verified.body,
    metadata: verified.storage_metadata
  )
end
```

This checks the active domain, address and mailbox, enters the configured tenant,
and yields an immutable `Destination` with `tenant_key`, `mailbox_id`, `address_id`,
`receiving_domain_id`, `recipient` and `owner_ref`. It returns the block's result,
creates no email or membership, starts no storage transaction, and requires no
ActionMailbox. Configure the optional mailbox registry and tenant adapter as usual.

Both APIs must be called after complete request verification. Destination values
are routing snapshots, not authorization tokens: an owner reference does not
prove a site still exists or that a sender may submit to it. Use records inside
their tenant context and recheck lifecycle/permissions when later work requires
it. Both APIs restore the previous tenant context when the block returns or raises.

## Carry Worker metadata with authenticated provenance

The default Worker protocol remains v2: it authenticates the raw message and SMTP envelope. Optional v3 also authenticates a bounded metadata object:

```json
{
  "source": "cloudflare",
  "data": {
    "archive_key": "inbound/example.eml"
  }
}
```

The `archive_key` above is an illustrative application-defined value. The gem does not fetch that object or verify an archive exists. Your trusted Worker constructs the data from sources whose provenance you understand.

V3 binds the encoded metadata to the timestamp, envelope, and exact raw bytes. The `X-CF-Email-Metadata` header is unpadded base64url UTF-8 JSON. Metadata attached to a v2 request is rejected rather than treated as authenticated. Existing v2 requests without metadata continue to work.

The Worker template exports `signedEmailHeaders` for an existing transport and `forwardEmail` for the bundled forwarding behavior. Keep your current archive and retry handling, and use the header builder to authenticate the original raw bytes:

```js
import { signedEmailHeaders } from "./cloudflare-ingress.js";

const headers = await signedEmailHeaders({
  secret: env.INGRESS_SECRET,
  raw, // Uint8Array from your bounded reader
  from: message.from,
  to: message.to,
  metadata: { source: "cloudflare", data: { archive_key: archiveKey } },
});
// Send exactly raw with these headers using your existing transport.
```

Here `cloudflare-ingress.js` is your local copy of the template's `src/index.js`. `raw` and `archiveKey` come from your existing bounded reader and archive operation. See the [Worker integration instructions](../templates/worker/README.md) for supported metadata values and forwarding behavior. Upgrade the Rails receiver before enabling v3 in the Worker.

In your Action Mailbox handler, read persisted metadata through the gem:

```ruby
require "cloudflare/email/provider_metadata"

metadata = Cloudflare::Email::ProviderMetadata.for(inbound_email)
archive_key = metadata&.dig("data", "archive_key")
```

This reads verified Active Storage metadata, not similarly named MIME headers. Authenticate your Worker first and preserve the verified object unchanged. Avoid adding secrets or unnecessary personal information to provider metadata.

**A valid Worker signature proves that your trusted Worker submitted the request. It does not prove the original email sender is authentic.** Even metadata labelled `source: "cloudflare"` is an assertion made by the holder of the ingress secret. Do not copy sender-controlled MIME headers into a “trusted authentication” field. If your existing Worker has reliable authentication evidence, preserve its documented provenance and let your application decide how that evidence affects acceptance. The gem intentionally does not infer SPF/DMARC results or implement a sender allowlist.

Retries with the same recipient, raw bytes, and metadata context reuse the inbound record. Aliases receive distinct membership context. Changing signed metadata produces a distinct checksum: stable values are preferable to per-attempt timestamps or random IDs. Keep downstream document extraction and external side effects idempotent too.

## Adopt incrementally

1. Inventory existing accepted addresses, organization/subdomain mappings, fallback destinations, and disabled sites. Backfill records explicitly; do not silently create a mailbox for every incoming address.
2. Confirm existing Worker routing for one organization's exact domain and activate only verified addresses. Exercise an alias, unknown address, suspended mailbox, and cross-tenant destination with synthetic mail.
3. Add request verification and preserve your current sender review, archive behavior, error responses, and size limits. Test that rejected or held mail cannot reach the processing queue.
4. Connect site provisioning to the same mailbox API used by the [management engine](management-engine.md). Scope the engine through existing host authentication and authorization.
5. Retire duplicate infrastructure only after comparing delivery and recovery behavior. Inbound adoption does not require switching your outbound provider.

Keep the shared operational communications history separate from tenant-local raw emails and mailbox membership when those serve different purposes. Define who owns deletion, archive retention, deduplication, and processing status; two competing delivery ledgers make recovery harder.

The gem's custom-ingress integration test exercises a custom controller against two real SQLite tenant databases, preserving binary MIME bytes and signed metadata before routing jobs run. It also verifies rejected metadata, host review, accepted-address enforcement, and retry behavior. It does not verify a deployed customer's Cloudflare DNS, Worker authentication evidence, R2 archive, or document-processing pipeline; those require that host's end-to-end tests.
