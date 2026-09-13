require File.join(MailboxKit::ROOT, "app/controllers/mailbox_kit/management/mailboxes_controller.rb")
module Cloudflare
  module Email
    module Management
      class MailboxesController < MailboxKit::Management::MailboxesController
      end
    end
  end
end
