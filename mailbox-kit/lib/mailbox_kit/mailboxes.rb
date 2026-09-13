# Explicit Active Record opt-in. Configure tenancy before requiring this file.
require "mailbox-kit"
require "mailbox_kit/tenancy"
require "mailbox_kit/mailboxes/configuration"
require "mailbox_kit/mailboxes/models"
require "mailbox_kit/mailboxes/service"
MailboxKit::Mailboxes.enable!

require "mailbox_kit/railtie" if defined?(::Rails::Railtie)
