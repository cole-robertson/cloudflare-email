require "rails/engine"
require "action_controller/railtie"

module Cloudflare
  module Email
    module Management
      class Engine < ::Rails::Engine
        isolate_namespace Cloudflare::Email::Management
        config.root = File.expand_path("../../../..", __dir__)

        config.paths["app/views"] << File.join(MailboxKit::ROOT, "app/views")

        config.paths["config/routes.rb"] = "lib/cloudflare/email/management/routes.rb"
      end
    end
  end
end
