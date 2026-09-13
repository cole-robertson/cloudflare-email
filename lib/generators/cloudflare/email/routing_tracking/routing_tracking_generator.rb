require "rails/generators"
require "rails/generators/active_record"

module Cloudflare
  module Email
    module Generators
      class RoutingTrackingGenerator < ::Rails::Generators::Base
        include ::ActiveRecord::Generators::Migration
        namespace "cloudflare:email:routing_tracking"
        source_root File.expand_path("templates", __dir__)
        class_option :migrations_path, type: :string, default: "db/migrate"

        def copy_tracking_migration
          migration_template "create_cloudflare_email_routing_delivery_receipts.rb",
            File.join(options[:migrations_path], "create_cloudflare_email_routing_delivery_receipts.rb")
        end

        def create_initializer
          create_file "config/initializers/cloudflare_email_routing_tracking.rb", <<~RUBY
            # Requires the outbox migration and Rails Active Record encryption keys.
            # This loads the API only; your application schedules analytics polling.
            require "cloudflare/email/active_record/routing_deliveries"
          RUBY
        end
      end
    end
  end
end
