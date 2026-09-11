require "rails/generators"
require "rails/generators/active_record"

module Cloudflare
  module Email
    module Generators
      class OutboxGenerator < ::Rails::Generators::Base
        include ::ActiveRecord::Generators::Migration
        namespace "cloudflare:email:outbox"
        source_root File.expand_path("templates", __dir__)
        class_option :migrations_path, type: :string, default: "db/migrate"

        def copy_outbox_migration
          migration_template "create_cloudflare_email_outbox.rb", File.join(options[:migrations_path], "create_cloudflare_email_outbox.rb")
        end

        def create_initializer
          create_file "config/initializers/cloudflare_email_outbox.rb", <<~RUBY
            # Opt in after running db:migrate. Never perform network delivery inside a database transaction.
            require "cloudflare/email/active_record"
            require "cloudflare/email/send_job"
            require "cloudflare/email/replay_events_job"
          RUBY
        end
      end
    end
  end
end
