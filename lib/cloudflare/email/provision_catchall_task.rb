require "cloudflare/email/task_base"
require "cloudflare/email/routing_provisioner"
require "cloudflare/email/worker_deployer"

module Cloudflare
  module Email
    # `bin/rails cloudflare:email:provision_catchall` — points a zone's
    # catch-all rule at the env-scoped ingress Worker. Useful for bounce
    # handling and alias routing. Applies to the entire Cloudflare zone.
    class ProvisionCatchallTask < TaskBase
      def self.call(domain:, worker_name: nil, io: $stdout)
        new(io: io, domain: domain, worker_name: worker_name).call
      end

      protected

      def run
        require_value!(management_token, "cloudflare.api_token or cloudflare.management_token")
        require_value!(opts[:domain],    "DOMAIN=example.com (the Cloudflare zone name)")

        worker = opts[:worker_name] || Cloudflare::Email::WorkerDeployer.default_script_name

        say "Provisioning zone-wide catch-all:"
        say "  Domain: #{opts[:domain]}"
        say "  Worker: #{worker}"
        say ""

        provisioner = Cloudflare::Email::RoutingProvisioner.new(api_token: management_token)
        provisioner.provision_catch_all_for_domain(domain: opts[:domain], worker_name: worker)

        say "  ✓ Catch-all on #{opts[:domain]} now points at #{worker}."
        say "  All unrouted addresses covered by this zone's catch-all will hit your Worker."
      end
    end
  end
end
