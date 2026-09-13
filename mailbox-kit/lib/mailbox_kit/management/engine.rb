require "rails/engine"
require "action_controller/railtie"

module MailboxKit
  module Management
    class Engine < ::Rails::Engine
      isolate_namespace MailboxKit::Management
      config.root = File.expand_path("../../..", __dir__)

      config.paths["config/routes.rb"] = "lib/mailbox_kit/management/routes.rb"
    end
  end
end
