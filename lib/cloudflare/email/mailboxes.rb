# Explicit opt-in. Configure Tenancy and Mailboxes before loading this file.
require "cloudflare-email"
require "cloudflare/email/tenancy"
require "cloudflare/email/mailboxes/configuration"
require "cloudflare/email/active_record"
require "cloudflare/email/mailboxes/models"
require "cloudflare/email/mailboxes/events"
require "cloudflare/email/mailboxes/service"
require "cloudflare/email/mailboxes/jobs"

Cloudflare::Email::Mailboxes.enable!
