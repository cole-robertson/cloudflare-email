require "cloudflare/email/routing_provisioner"
require "cloudflare/email/worker_deployer"

module Cloudflare
  module Email
    # Implementation for `bin/rails cloudflare:email:provision_route`.
    # Zero-dashboard setup of a Cloudflare Email Routing rule that forwards
    # mail for a specific address to the env-scoped ingress Worker.
    #
    #   ADDRESS=cole@in.example.com bin/rails cloudflare:email:provision_route
    #
    # Automatically targets the current Rails environment's Worker
    # (cloudflare-email-ingress-#{Rails.env}). Override with WORKER=name.
    class ProvisionRouteTask
      def self.call(address:, worker_name: nil, io: $stdout)
        new(address: address, worker_name: worker_name, io: io).call
      end

      def initialize(address:, worker_name: nil, io: $stdout)
        @address     = address.to_s
        @worker_name = worker_name || Cloudflare::Email::WorkerDeployer.default_script_name
        @io          = io
      end

      def call
        require "cloudflare/email/credentials"
        api_token = Cloudflare::Email::Credentials.management_token
        raise "Missing cloudflare.api_token or cloudflare.management_token (Rails credentials or env var)" if api_token.empty?
        raise "Missing ADDRESS=address@domain" if @address.empty?

        @io.puts "Provisioning Email Routing:"
        @io.puts "  Address: #{@address}"
        @io.puts "  Worker:  #{@worker_name}"
        @io.puts ""

        provisioner = Cloudflare::Email::RoutingProvisioner.new(api_token: api_token)
        provisioner.provision(address: @address, worker_name: @worker_name)

        @io.puts "  ✓ Route created/updated — mail to #{@address} will hit Worker #{@worker_name}."
        0
      rescue Cloudflare::Email::Error => e
        @io.puts "  ERROR: #{e.message}"
        @io.puts "  Status: #{e.status}"
        @io.puts "  (API token needs Zone → Zone → Read and Zone → Email Routing → Edit.)"
        1
      rescue => e
        @io.puts "  ERROR: #{e.message}"
        1
      end

    end
  end
end
