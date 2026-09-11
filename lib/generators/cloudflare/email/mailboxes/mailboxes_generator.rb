require "rails/generators"
require "rails/generators/active_record"
require "generators/cloudflare/email/outbox/outbox_generator"
require "generators/cloudflare/email/tracking/tracking_generator"

module Cloudflare
  module Email
    module Generators
      class MailboxesGenerator < ::Rails::Generators::Base
        include ::ActiveRecord::Generators::Migration
        namespace "cloudflare:email:mailboxes"
        source_root File.expand_path("templates", __dir__)
        class_option :tenant_migrations_path, type: :string, default: "db/migrate",
          desc: "Migration directory applied to every tenant database"
        class_option :directory_migrations_path, type: :string, default: "db/migrate",
          desc: "Migration directory applied only to the shared directory database"

        def copy_migrations
          invoke "cloudflare:email:outbox", [], migrations_path: options[:tenant_migrations_path]
          invoke "cloudflare:email:tracking", [], migrations_path: options[:tenant_migrations_path]
          migration_template "create_cloudflare_email_receiving_domains.rb",
            File.join(options[:directory_migrations_path], "create_cloudflare_email_receiving_domains.rb")
          migration_template "create_cloudflare_email_shared_events.rb",
            File.join(options[:directory_migrations_path], "create_cloudflare_email_shared_events.rb")
          migration_template "create_cloudflare_email_mailboxes.rb",
            File.join(options[:tenant_migrations_path], "create_cloudflare_email_mailboxes.rb")
        end

        def create_initializer
          create_file "config/initializers/00_cloudflare_email_tenancy.rb", <<~RUBY
            # Single database: no configuration is necessary.
            # Separate tenant databases: configure BEFORE the optional models load.
            # Replace these application-specific adapter names with your own:
            # require "cloudflare/email/tenancy"
            # Cloudflare::Email::Tenancy.configure(
            #   base_class: TenantRecord,
            #   switch: ->(key, &block) { TenantRecord.with_tenant(key, &block) },
            #   current: -> { TenantRecord.current_tenant }
            # )
            # require "cloudflare/email/mailboxes/configuration"
            # Cloudflare::Email::Mailboxes.configure(directory_base: SharedRecord)
            # ActionMailbox and ActiveStorage must use this same tenant connection.
            # See docs/mailboxes.md for the complete application setup.
          RUBY
          create_file "config/initializers/cloudflare_email_mailboxes.rb", <<~RUBY
            # Optional mailbox persistence. Run the generated migrations first.
            # For database tenancy, configure Tenancy and the shared directory
            # base before requiring cloudflare/email/mailboxes. See docs/mailboxes.md.
            require "cloudflare/email/mailboxes"
          RUBY
        end
      end
    end
  end
end
