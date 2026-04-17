require "cloudflare/email/worker_deployer"

module Cloudflare
  module Email
    # Implementation for `bin/rails cloudflare:email:deploy_worker`.
    # Uploads the Worker script + both required secrets via the Cloudflare API.
    # No wrangler / Node / npm required.
    class DeployWorkerTask
      def self.call(script_path: nil, ingress_url: nil, io: $stdout)
        new(script_path: script_path, ingress_url: ingress_url, io: io).call
      end

      def initialize(script_path: nil, ingress_url: nil, io: $stdout)
        @script_path = script_path
        @ingress_url = ingress_url
        @io          = io
      end

      def call
        require "cloudflare/email/credentials"
        account_id     = Cloudflare::Email::Credentials.account_id
        api_token      = Cloudflare::Email::Credentials.management_token
        ingress_secret = Cloudflare::Email::Credentials.ingress_secret
        ingress_url    = @ingress_url || ENV["RAILS_INGRESS_URL"]

        raise_missing("cloudflare.account_id") if account_id.empty?
        raise_missing("cloudflare.api_token (or cloudflare.management_token)") if api_token.empty?
        raise_missing("cloudflare.ingress_secret — run the installer or set it in credentials") if ingress_secret.empty?

        script_path = @script_path || default_script_path
        unless File.exist?(script_path)
          raise "Worker script not found at #{script_path} — re-run " \
                "`bin/rails g cloudflare:email:install` to scaffold it"
        end

        deployer = Cloudflare::Email::WorkerDeployer.new(
          account_id: account_id, api_token: api_token,
        )

        @io.puts "  Deploying Worker '#{deployer.script_name}'..."
        deployer.deploy(script_path: script_path)
        @io.puts "  ✓ Worker script deployed"

        deployer.put_secret("INGRESS_SECRET", ingress_secret)
        @io.puts "  ✓ INGRESS_SECRET set"

        if ingress_url.to_s.empty?
          @io.puts "  (skipping RAILS_INGRESS_URL — pass URL=https://... or set RAILS_INGRESS_URL env var)"
        else
          deployer.put_secret("RAILS_INGRESS_URL", ingress_url)
          @io.puts "  ✓ RAILS_INGRESS_URL set to #{ingress_url}"
        end

        @io.puts ""
        @io.puts "  Next: in Cloudflare dashboard → Email → Email Routing → Routes,"
        @io.puts "  route your address to Worker '#{deployer.script_name}'."
        0
      rescue Cloudflare::Email::Error => e
        @io.puts "  ERROR: #{e.message}"
        @io.puts "  Status: #{e.status}"
        @io.puts "  (Check that your API token has Account → Workers Scripts → Edit permission.)"
        1
      rescue => e
        @io.puts "  ERROR: #{e.message}"
        1
      end

      private

      def default_script_path
        candidates = [
          "cloudflare-worker/src/index.js",
          "cloudflare-worker/src/index.ts",
        ]
        candidates.find { |p| File.exist?(p) } || candidates.first
      end

      def raise_missing(what)
        raise "Missing #{what}. Run `bin/rails credentials:edit` (or set the CLOUDFLARE_* env var)."
      end
    end
  end
end
