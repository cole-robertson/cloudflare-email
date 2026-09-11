module Cloudflare
  module Email
    module Management
      class StylesController < ActionController::Base
        def show
          response.headers["X-Content-Type-Options"] = "nosniff"
          send_data File.binread(File.expand_path("../../../../../lib/cloudflare/email/management/management.css", __dir__)),
            type: "text/css; charset=utf-8", disposition: "inline"
        end
      end
    end
  end
end
