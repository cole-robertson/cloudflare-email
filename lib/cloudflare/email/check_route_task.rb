require "cloudflare/email/credentials"
require "cloudflare/email/routing_diagnostics"
require "cloudflare/email/worker_deployer"

module Cloudflare
  module Email
    class CheckRouteTask
      def self.call(address:, worker_name: nil, account_id: nil, io: $stdout)
        report = RoutingDiagnostics.new(api_token: Credentials.management_token).check(
          address: address, worker_name: worker_name || WorkerDeployer.default_script_name,
          account_id: account_id || Credentials.account_id)
        report[:checks].each { |check| io.puts "#{check[:status].upcase} #{check[:name]}: #{check[:message]}" }
        io.puts report[:limitations]
        report[:status] == "pass" ? 0 : 1
      rescue StandardError
        io.puts "UNKNOWN: Unable to inspect routing. Check ADDRESS, WORKER_NAME, and Cloudflare management credentials."
        1
      end
    end
  end
end
