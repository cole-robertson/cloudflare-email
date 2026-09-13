require "rails/generators"
require "rails/generators/active_record"

module MailboxKit
  module Generators
    class UpgradeGenerator < ::Rails::Generators::Base
      include ::ActiveRecord::Generators::Migration
      namespace "mailbox_kit:upgrade"
      source_root File.expand_path("templates", __dir__)
      class_option :tenant_migrations_path, type: :string, default: "db/migrate",
        desc: "Migration directory applied to each database containing mailbox messages"

      def copy_migration
        migration_template "index_mailbox_kit_inbound_messages.rb",
          File.join(options[:tenant_migrations_path], "index_mailbox_kit_inbound_messages.rb")
      end
    end
  end
end
