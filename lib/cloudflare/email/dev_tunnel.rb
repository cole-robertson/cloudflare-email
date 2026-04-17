require "open3"

module Cloudflare
  module Email
    # `bin/rails cloudflare:email:dev` — spins up a cloudflared tunnel, updates
    # the deployed Worker's RAILS_INGRESS_URL secret, and tails Worker logs.
    # Keeps running until Ctrl-C.
    class DevTunnel
      INGRESS_PATH = "/rails/action_mailbox/cloudflare/inbound_emails".freeze
      WORKER_NAME  = "cloudflare-email-ingress".freeze

      def self.call(port: 3000, io: $stdout)
        new(port: port, io: io).call
      end

      def initialize(port:, io: $stdout)
        @port = port
        @io   = io
        @tunnel_pid = nil
      end

      def call
        check_prerequisites
        start_tunnel
        tunnel_url = wait_for_tunnel_url
        @io.puts "  Tunnel:  #{tunnel_url}"

        ingress_url = "#{tunnel_url}#{INGRESS_PATH}"
        update_worker_secret(ingress_url)
        @io.puts "  Worker RAILS_INGRESS_URL updated → #{ingress_url}"
        @io.puts ""
        @io.puts "  Send mail to your routed address; it'll land in this Rails app."
        @io.puts "  Ctrl-C to stop."
        @io.puts ""

        trap("INT")  { cleanup; exit 0 }
        trap("TERM") { cleanup; exit 0 }

        # Tail Worker logs inline.
        system("wrangler", "tail", WORKER_NAME)
      ensure
        cleanup
      end

      private

      def check_prerequisites
        raise "cloudflared not found in PATH — install from https://developers.cloudflare.com/cloudflared/" \
          unless system("command -v cloudflared >/dev/null 2>&1")
        raise "wrangler not found in PATH — run `npm i -g wrangler`" \
          unless system("command -v wrangler >/dev/null 2>&1")
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

      def update_worker_secret(url)
        out, err, status = Open3.capture3(
          "wrangler", "secret", "put", "RAILS_INGRESS_URL", "--name", WORKER_NAME,
          stdin_data: url,
        )
        unless status.success?
          raise "wrangler secret put failed: #{err.empty? ? out : err}"
        end
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
