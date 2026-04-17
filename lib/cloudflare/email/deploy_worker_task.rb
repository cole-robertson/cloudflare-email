require "cloudflare/email/task_base"
require "cloudflare/email/worker_deployer"

module Cloudflare
  module Email
    # `bin/rails cloudflare:email:deploy_worker` — uploads the Worker
    # script + both secrets via the Cloudflare API. No wrangler required.
    class DeployWorkerTask < TaskBase
      def self.call(script_path: nil, ingress_url: nil, io: $stdout)
        new(io: io, script_path: script_path, ingress_url: ingress_url).call
      end

      protected

      def run
        require_value!(account_id,     "cloudflare.account_id")
        require_value!(management_token, "cloudflare.api_token (or cloudflare.management_token)")
        require_value!(ingress_secret, "cloudflare.ingress_secret — run the installer first")

        path = script_path
        raise "Worker script not found at #{path} — re-run `bin/rails g cloudflare:email:install`" unless File.exist?(path)

        deployer = Cloudflare::Email::WorkerDeployer.new(
          account_id: account_id, api_token: management_token,
        )

        say "  Deploying Worker '#{deployer.script_name}'..."
        deployer.deploy(script_path: path)
        say "  ✓ Worker script deployed"

        deployer.put_secret("INGRESS_SECRET", ingress_secret)
        say "  ✓ INGRESS_SECRET set"

        if url.to_s.empty?
          say "  (skipping RAILS_INGRESS_URL — pass URL=https://... or set RAILS_INGRESS_URL env var)"
        else
          deployer.put_secret("RAILS_INGRESS_URL", url)
          say "  ✓ RAILS_INGRESS_URL set to #{url}"
        end

        say ""
        say "  Next: route an address to Worker '#{deployer.script_name}' — either via"
        say "  `bin/rails cloudflare:email:provision_route ADDRESS=...` or in the dashboard."
      end

      private

      def script_path
        opts[:script_path] || default_script_path
      end

      def url
        opts[:ingress_url] || ENV["RAILS_INGRESS_URL"].to_s
      end

      def default_script_path
        candidates = ["cloudflare-worker/src/index.js", "cloudflare-worker/src/index.ts"]
        candidates.find { |p| File.exist?(p) } || candidates.first
      end
    end
  end
end
