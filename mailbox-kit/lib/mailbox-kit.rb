require "mailbox_kit/version"
require "mailbox_kit/error"

module MailboxKit
  ROOT = File.expand_path("..", __dir__).freeze
  module Mailboxes
    def self.enabled? = @enabled == true
  end
end

require "mailbox_kit/railtie" if defined?(::Rails::Railtie)
