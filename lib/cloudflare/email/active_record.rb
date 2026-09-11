# Optional durable Rails/ActiveRecord integration. Jobs are a separate opt-in.
require "cloudflare/email/active_record/outbox"
require "cloudflare/email/active_record/mail_snapshot"
require "cloudflare/email/active_record/delivery_events"
require "cloudflare/email/active_record/outbox_notifications"
