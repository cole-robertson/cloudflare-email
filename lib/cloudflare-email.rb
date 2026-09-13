require "mailbox-kit"
module Cloudflare
  module Email
    Mailboxes = MailboxKit::Mailboxes
  end
end
require "cloudflare/email/version"
require "cloudflare/email/error"
require "cloudflare/email/response"
require "cloudflare/email/signing"
require "cloudflare/email/envelope"
require "cloudflare/email/credentials"
require "cloudflare/email/client"
require "cloudflare/email/message_id"
require "cloudflare/email/delivery_event"
require "cloudflare/email/event_consumer"

require "cloudflare/email/engine" if defined?(::Rails::Engine)
