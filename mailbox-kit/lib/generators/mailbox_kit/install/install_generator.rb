require "rails/generators"
require "rails/generators/active_record"
module MailboxKit
  module Generators
    class InstallGenerator < ::Rails::Generators::Base
      include ::ActiveRecord::Generators::Migration
      namespace "mailbox_kit:install"
      source_root File.expand_path("templates", __dir__)
      class_option :tenant_migrations_path, type: :string, default: "db/migrate"
      class_option :directory_migrations_path, type: :string, default: "db/migrate"
      def copy_migrations
        migration_template "create_mailbox_kit_receiving_domains.rb", File.join(options[:directory_migrations_path], "create_mailbox_kit_receiving_domains.rb")
        migration_template "create_mailbox_kit_mailboxes.rb", File.join(options[:tenant_migrations_path], "create_mailbox_kit_mailboxes.rb")
      end
      def create_initializer
        create_file "config/initializers/mailbox_kit.rb", <<~RUBY
          # Single database by default. Configure MailboxKit::Tenancy before
          # requiring mailbox models when using separate tenant databases.
          require "mailbox_kit/mailboxes"
        RUBY
      end
    end
  end
end
