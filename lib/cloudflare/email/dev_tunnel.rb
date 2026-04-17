require "cloudflare/email/worker_deployer"

module Cloudflare
  module Email
    # `bin/rails cloudflare:email:dev` — spins up a cloudflared tunnel and
    # updates the deployed Worker's RAILS_INGRESS_URL secret so inbound mail
    # can flow through to this local Rails server. No wrangler required.
    class DevTunnel
      INGRESS_PATH = "/rails/action_mailbox/cloudflare/inbound_emails".freeze

      def self.call(port: 3000, io: $stdout)
        new(port: port, io: io).call
      end

      def initialize(port:, io: $stdout)
        @port       = port
        @io         = io
        @tunnel_pid = nil
      end

      def call
        check_prerequisites

        require "cloudflare/email/credentials"
        deployer = Cloudflare::Email::WorkerDeployer.new(
          account_id: Cloudflare::Email::Credentials.account_id,
          api_token:  Cloudflare::Email::Credentials.management_token,
        )

        start_tunnel
        tunnel_url = wait_for_tunnel_url
        @io.puts "  Tunnel:  #{tunnel_url}"

        ingress_url = "#{tunnel_url}#{INGRESS_PATH}"
        deployer.put_secret("RAILS_INGRESS_URL", ingress_url)
        @io.puts "  Worker '#{deployer.script_name}' RAILS_INGRESS_URL updated → #{ingress_url}"
        @io.puts ""
        @io.puts "  Send mail to your routed address; it'll land in this Rails app."
        @io.puts "  Ctrl-C to stop."
        @io.puts ""

        trap("INT")  { cleanup; exit 0 }
        trap("TERM") { cleanup; exit 0 }

        # Stay alive so the tunnel keeps running. The user stops us with Ctrl-C.
        sleep
      ensure
        cleanup
      end

      private

      def check_prerequisites
        unless system("command -v cloudflared >/dev/null 2>&1")
          raise "cloudflared not found in PATH — install from https://developers.cloudflare.com/cloudflared/"
        end
        require "cloudflare/email/credentials"
        if Cloudflare::Email::Credentials.account_id.empty? ||
           Cloudflare::Email::Credentials.management_token.empty?
          raise "Missing cloudflare.account_id or cloudflare.api_token in credentials " \
                "(or CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_API_TOKEN env vars)"
        end
      end

      def start_tunnel
        @io.puts "  Starting cloudflared tunnel on :#{@port}..."
        @tunnel_log = File.open("/tmp/cloudflare-email-dev-tunnel.log", "w")
        @tunnel_pid = spawn(
          "cloudflared", "tunnel", "--url", "http://127.0.0.1:#{@port}",
          out: @tunnel_log, err: @tunnel_log,
        )
      end

      def wait_for_tunnel_url
        deadline = Time.now + 30
        while Time.now < deadline
          sleep 0.5
          log = File.read("/tmp/cloudflare-email-dev-tunnel.log") rescue ""
          if (match = log.match(%r{https://[a-z0-9\-]+\.trycloudflare\.com}))
            return match[0]
          end
        end
        raise "Timed out waiting for cloudflared to return a tunnel URL"
      end

      def cleanup
        if @tunnel_pid
          Process.kill("TERM", @tunnel_pid) rescue nil
          Process.wait(@tunnel_pid) rescue nil
          @tunnel_pid = nil
        end
        @tunnel_log&.close
      end

    end
  end
end
