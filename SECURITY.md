# Security

The current hardening work targets the unreleased 0.2.0 branch. The published
0.1.0 gem does not include it. Use a reviewed commit containing the fixes until
a release is published, and redeploy the bundled Worker when upgrading.

Rails integration is tested on patched Rails 7.2, 8.0, and 8.1; application
owners must update their own Rails, database adapter, and other dependencies.
The gem does not add Rails or SQLite as runtime dependencies.

Report sensitive findings privately to the maintainer at cole@dscribeai.com.
Include affected versions and impact; omit real credentials and private mail.
Do not place secrets or private message data in public issues.

## Deployment responsibilities

- Keep API and management tokens least-privileged and separate. Store tokens and
  a strong ingress secret in a secret manager or Rails encrypted credentials.
  Rotate compromised secrets on Rails and the Worker together. HTTPS endpoint
  overrides are trusted operator configuration; never derive them from mail.
- Set request-size limits, timeouts and rate limits at the proxy/server. Rails
  and the Worker bound MIME reads to 25 MiB by default (`MAX_EMAIL_BYTES`), but
  cannot prevent upstream buffering or slow clients. Limits apply to raw MIME,
  not just decoded attachments.
- Treat mail and attachments as untrusted content. The gem authenticates Worker
  transport and SMTP envelope metadata, not a human sender's identity. Rendering,
  sanitization, malware scanning and application authorization belong to the app.
- Protect raw MIME, attachments, outbox snapshots and event receipts with access
  control, storage encryption, backups and retention policies. Avoid logging raw
  responses/errors: provider details and application logs can contain private mail.
- Restrict queue producers and consumers. Event account/domain checks are
  validation, not cryptographic signatures. Monitor unacknowledged malformed
  messages, processing failures and unmatched receipts.
- Database administrators and direct SQL writes are trusted. ActiveRecord
  read-only evidence fields do not provide tamper-proof storage. Keep tenant
  authorization around outbox operations and receipt access in the application.
- Development tunnels expose the ingress to the internet. Use the bundled task,
  dedicated development mail routes and test data; stop tunnels when finished.
  The Host guard restricts routing but is not a sandbox for the development app
  or a replacement for safe error pages and request logging.

See [the September 11 security review](docs/verification/2026-09-11-security.md)
for findings, verification, and remaining limits.
