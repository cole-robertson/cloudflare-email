require "active_record"
require "mailbox_kit/error"
module MailboxKit
  module Mailboxes
    class Unavailable < MailboxKit::Error; end
    class << self
      def configure(directory_base: ::ActiveRecord::Base)
        raise ConfigurationError, "configure mailboxes before loading mailbox models" if const_defined?(:ReceivingDomain, false)
        unless directory_base.is_a?(Class) && directory_base <= ::ActiveRecord::Base
          raise ConfigurationError, "directory_base must be an ActiveRecord base class"
        end
        @directory_base = directory_base
      end
      def directory_base = @directory_base || ::ActiveRecord::Base
      def enabled? = @enabled == true
      def enable! = @enabled = true
    end
  end
end
