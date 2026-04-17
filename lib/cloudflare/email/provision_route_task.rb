require "cloudflare/email/task_base"
require "cloudflare/email/routing_provisioner"
require "cloudflare/email/worker_deployer"

module Cloudflare
  module Email
    # `bin/rails cloudflare:email:provision_route` — creates a Cloudflare
    # Email Routing rule binding ADDRESS to the env-scoped ingress Worker.
    class ProvisionRouteTask < TaskBase
      def self.call(address:, worker_name: nil, io: $stdout)
        new(io: io, address: address, worker_name: worker_name).call
      end

      protected

      def run
        require_value!(management_token, "cloudflare.api_token or cloudflare.management_token")
        require_value!(opts[:address],   "ADDRESS=address@domain")

        worker = opts[:worker_name] || Cloudflare::Email::WorkerDeployer.default_script_name

        say "Provisioning Email Routing:"
        say "  Address: #{opts[:address]}"
        say "  Worker:  #{worker}"
        say ""

        provisioner = Cloudflare::Email::RoutingProvisioner.new(api_token: management_token)
        provisioner.provision(address: opts[:address], worker_name: worker)

        say "  ✓ Route created/updated — mail to #{opts[:address]} will hit Worker #{worker}."
      end
    end
  end
end
