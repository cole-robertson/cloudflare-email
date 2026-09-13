require "mailbox-kit"
require "mailbox_kit/management/adapter"
module Cloudflare
  module Email
    module Management
      Adapter = MailboxKit::Management::Adapter
    end
  end
end
