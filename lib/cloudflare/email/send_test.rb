require "cloudflare/email/task_base"
require "cloudflare/email/client"

module Cloudflare
  module Email
    # `bin/rails cloudflare:email:send_test TO=... [FROM=...]` — one-shot
    # test send via the current Cloudflare Email config.
    class SendTest < TaskBase
      def self.call(to:, from: nil, io: $stdout)
        new(io: io, to: to, from: from).call
      end

      protected

      def run
        require_value!(account_id, "cloudflare.account_id")
        require_value!(api_token,  "cloudflare.api_token")
        require_value!(opts[:to],  "TO=recipient@example.com")

        sender = opts[:from] || infer_from
        raise "Missing FROM= and couldn't infer from verified sending domains" if sender.to_s.empty?

        say "Sending test email:"
        say "  from: #{sender}"
        say "  to:   #{opts[:to]}"
        say ""

        client = Cloudflare::Email::Client.new(
          account_id: account_id, api_token: api_token, retries: 0,
        )

        response = client.send(
          from:    sender,
          to:      opts[:to],
          subject: "[cloudflare-email test] #{Time.now.iso8601}",
          text:    "This is a test send from the cloudflare-email gem doctor.",
          html:    "<p>This is a test send from the <code>cloudflare-email</code> gem doctor.</p>" \
                   "<p>Sent at <strong>#{Time.now.iso8601}</strong>.</p>",
        )

        say "  success:   #{response.success?}"
        say "  delivered: #{response.delivered.inspect}"
        say "  queued:    #{response.queued.inspect}"           if response.queued.any?
        say "  bounces:   #{response.permanent_bounces.inspect}" if response.permanent_bounces.any?
      end

      private

      def infer_from
        require "net/http"
        require "json"

        uri  = URI.parse("https://api.cloudflare.com/client/v4/accounts/#{account_id}/email/sending/domains")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 10

        req = Net::HTTP::Get.new(uri.request_uri)
        req["Authorization"] = "Bearer #{api_token}"
        response = http.request(req)
        return nil unless response.code.to_i.between?(200, 299)

        domains  = JSON.parse(response.body).dig("result") || []
        verified = domains.find { |d| d["verified"] == true || d["status"] == "verified" }
        return nil unless verified

        domain = verified["name"] || verified["domain"]
        domain.to_s.empty? ? nil : "test@#{domain}"
      rescue StandardError
        nil
      end
    end
  end
end
