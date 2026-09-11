require "rails/generators"
require "rails/generators/active_record"

module Cloudflare
  module Email
    module Generators
      class TrackingGenerator < ::Rails::Generators::Base
        include ::ActiveRecord::Generators::Migration
        namespace "cloudflare:email:tracking"
        source_root File.expand_path("templates", __dir__)
        class_option :migrations_path, type: :string, default: "db/migrate"

        def copy_tracking_migration
          migration_template "create_cloudflare_email_event_receipts.rb", File.join(options[:migrations_path], "create_cloudflare_email_event_receipts.rb")
        end

        def create_initializer
          create_file "config/initializers/cloudflare_email_tracking.rb", <<~RUBY
            # Opt in to durable delivery-event receipts after running db:migrate.
            require "cloudflare/email/active_record/event_inbox"
          RUBY
        end
      end
    end
  end
end
