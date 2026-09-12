require "rails/generators"
require "rails/generators/active_record"

module Cloudflare
  module Email
    module Generators
      class CatchAllGenerator < ::Rails::Generators::Base
        include ::ActiveRecord::Generators::Migration
        namespace "cloudflare:email:mailboxes:catch_all"
        source_root File.expand_path("templates", __dir__)
        class_option :tenant_migrations_path, type: :string, default: "db/migrate",
          desc: "Migration directory applied to every tenant database"

        def copy_migration
          migration_template "add_cloudflare_email_catch_all.rb",
            File.join(options[:tenant_migrations_path], "add_cloudflare_email_catch_all.rb")
        end
      end
    end
  end
end
