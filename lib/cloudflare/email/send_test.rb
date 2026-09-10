require "cloudflare/email/task_base"
require "cloudflare/email/client"
require "time"

module Cloudflare
  module Email
    # `bin/rails cloudflare:email:send_test TO=... FROM=...` — one-shot
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

        sender = require_value!(opts[:from], "FROM=sender@your-verified-domain.example")

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
        say "  message_id: #{response.message_id}" if response.message_id
        say "  delivered: #{response.delivered.inspect}"
        say "  queued:    #{response.queued.inspect}"           if response.queued.any?
        say "  bounces:   #{response.permanent_bounces.inspect}" if response.permanent_bounces.any?
        say "  suppressed: #{response.suppressed_recipients.inspect}" if response.suppressed_recipients.any?
      end

    end
  end
end
