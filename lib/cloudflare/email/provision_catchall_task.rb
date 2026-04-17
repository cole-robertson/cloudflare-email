require "cloudflare/email/routing_provisioner"
require "cloudflare/email/worker_deployer"
require "cloudflare/email/credentials"

module Cloudflare
  module Email
    # Implementation for `bin/rails cloudflare:email:provision_catchall`.
    # Configures the zone's catch-all rule to send every otherwise-unrouted
    # address to the env-scoped ingress Worker. Essential for SecureReply
    # reply addresses (where each address is unique) and bounces.
    #
    #   DOMAIN=in.example.com bin/rails cloudflare:email:provision_catchall
    class ProvisionCatchallTask
      def self.call(domain:, worker_name: nil, io: $stdout)
        new(domain: domain, worker_name: worker_name, io: io).call
      end

      def initialize(domain:, worker_name: nil, io: $stdout)
        @domain      = domain.to_s
        @worker_name = worker_name || Cloudflare::Email::WorkerDeployer.default_script_name
        @io          = io
      end

      def call
        api_token = Cloudflare::Email::Credentials.management_token
        raise "Missing cloudflare.api_token or cloudflare.management_token" if api_token.empty?
        raise "Missing DOMAIN=in.example.com" if @domain.empty?

        @io.puts "Provisioning catch-all:"
        @io.puts "  Domain: #{@domain}"
        @io.puts "  Worker: #{@worker_name}"
        @io.puts ""

        provisioner = Cloudflare::Email::RoutingProvisioner.new(api_token: api_token)
        provisioner.provision_catch_all_for_domain(domain: @domain, worker_name: @worker_name)

        @io.puts "  ✓ Catch-all on #{@domain} now points at #{@worker_name}."
        @io.puts "  All unrouted addresses on this domain will hit your Worker."
        0
      rescue Cloudflare::Email::Error => e
        @io.puts "  ERROR: #{e.message}"
        @io.puts "  Status: #{e.status}"
        1
      rescue => e
        @io.puts "  ERROR: #{e.message}"
        1
      end
    end
  end
end
