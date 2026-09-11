module Cloudflare
  module Email
    # cloudflared forces this origin Host. Restrict tunnel traffic before Rails
    # routing, debug middleware and normal host authorization execute.
    class DevIngressGuard
      HOST = "cloudflare-email-ingress.localhost".freeze
      PATH = "/rails/action_mailbox/cloudflare/inbound_emails".freeze
      RESPONSE_HEADER = "x-cloudflare-email-ingress-only".freeze

      def initialize(app)
        @app = app
      end

      def call(env)
        return @app.call(env) unless env["HTTP_HOST"].to_s.downcase.split(":", 2).first == HOST
        unless env["REQUEST_METHOD"] == "POST" && env["PATH_INFO"] == PATH
          return [404, { "content-type" => "text/plain", "content-length" => "0", RESPONSE_HEADER => "1" }, []]
        end
        forwarded = env.dup
        forwarded["HTTP_HOST"] = "localhost"
        forwarded.delete("HTTP_X_FORWARDED_HOST")
        forwarded.delete("HTTP_FORWARDED")
        @app.call(forwarded)
      end
    end
  end
end
