require "cloudflare/email/error"
require "mailbox_kit/tenancy"
module Cloudflare
  module Email
    Tenancy = MailboxKit::Tenancy
  end
end
