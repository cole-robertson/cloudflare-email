require "cloudflare/email/client"

module Cloudflare
  module Email
    # One-shot test send for `bin/rails cloudflare:email:send_test`.
    #
    #   TO=you@example.com bin/rails cloudflare:email:send_test
    #   TO=you@example.com FROM=agent@acme.com bin/rails cloudflare:email:send_test
    class SendTest
      def self.call(to:, from: nil, io: $stdout)
        new(to: to, from: from, io: io).call
      end

      def initialize(to:, from: nil, io: $stdout)
        @to   = to
        @from = from
        @io   = io
      end

      def call
        account_id = Rails.application.credentials.dig(:cloudflare, :account_id) || ENV["CLOUDFLARE_ACCOUNT_ID"]
        api_token  = Rails.application.credentials.dig(:cloudflare, :api_token)  || ENV["CLOUDFLARE_API_TOKEN"]

        raise "Missing cloudflare.account_id in credentials" if account_id.to_s.empty?
        raise "Missing cloudflare.api_token in credentials"  if api_token.to_s.empty?
        raise "Missing TO= (recipient)"                      if @to.to_s.empty?

        from = @from || infer_from(api_token, account_id)
        raise "Missing FROM= (sender) and could not infer from verified sending domains" if from.to_s.empty?

        @io.puts "Sending test email:"
        @io.puts "  from: #{from}"
        @io.puts "  to:   #{@to}"
        @io.puts ""

        client = Cloudflare::Email::Client.new(
          account_id: account_id,
          api_token:  api_token,
          retries:    0,
        )

        response = client.send(
          from:    from,
          to:      @to,
          subject: "[cloudflare-email test] #{Time.now.iso8601}",
          text:    "This is a test send from the cloudflare-email gem doctor.",
          html:    "<p>This is a test send from the <code>cloudflare-email</code> gem doctor.</p>" \
                   "<p>Sent at <strong>#{Time.now.iso8601}</strong>.</p>",
        )

        @io.puts "  success:   #{response.success?}"
        @io.puts "  delivered: #{response.delivered.inspect}"
        @io.puts "  queued:    #{response.queued.inspect}" if response.queued.any?
        @io.puts "  bounces:   #{response.permanent_bounces.inspect}" if response.permanent_bounces.any?
        @io.puts ""
        response.success? ? 0 : 1
      rescue Cloudflare::Email::Error => e
        @io.puts "  ERROR: #{e.class}: #{e.message}"
        @io.puts "  status: #{e.status}"
        @io.puts "  response: #{e.response.inspect}"
        1
      end

      private

      def infer_from(api_token, account_id)
        uri  = URI.parse("https://api.cloudflare.com/client/v4/accounts/#{account_id}/email/sending/domains")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 10

        req = Net::HTTP::Get.new(uri.request_uri)
        req["Authorization"] = "Bearer #{api_token}"

        response = http.request(req)
        return nil unless response.code.to_i.between?(200, 299)

        domains = JSON.parse(response.body).dig("result") || []
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
