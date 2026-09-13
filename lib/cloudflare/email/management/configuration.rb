require "mailbox_kit/management/configuration"
module Cloudflare
  module Email
    module Management
      Configuration = MailboxKit::Management::Configuration
      def self.configuration = MailboxKit::Management.configuration
      def self.configure(&block) = MailboxKit::Management.configure(&block)
    end
  end
end
