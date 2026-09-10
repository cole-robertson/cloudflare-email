require "net/http"
require "json"

module Cloudflare
  module Email
    # Diagnostic runner for `bin/rails cloudflare:email:doctor`.
    # Verifies each layer of configuration independently so a new user can
    # see exactly which piece is misconfigured.
    class Doctor
      OK    = :ok
      WARN  = :warn
      FAIL  = :fail
      SKIP  = :skip

      def self.call(io: $stdout)
        new(io: io).call
      end

      def initialize(io: $stdout)
        @io      = io
        @results = []
      end

      def call
        header
        check_rails_loaded
        check_credentials
        check_api_token
        check_account_access
        check_sending_domains
        check_ingress_secret
        check_token_split
        check_action_mailbox_ingress
        check_delivery_method_registered
        summary
        @results.any? { |r| r[:status] == FAIL } ? 1 : 0
      end

      private

      def header
        @io.puts "cloudflare-email doctor — v#{Cloudflare::Email::VERSION}"
        @io.puts ""
      end

      def check_rails_loaded
        if defined?(Rails) && Rails.application
          record("Rails app", OK, "#{Rails.application.class.name} (#{Rails.env})")
        else
          record("Rails app", FAIL, "Rails.application not loaded — run via bin/rails")
        end
      end

      def check_credentials
        account_id = credential(:account_id)
        api_token  = credential(:api_token)

        if account_id.to_s.empty?
          record("credentials.cloudflare.account_id", FAIL, "missing — run bin/rails credentials:edit")
        else
          record("credentials.cloudflare.account_id", OK, account_id)
        end

        if api_token.to_s.empty?
          record("credentials.cloudflare.api_token", FAIL, "missing — run bin/rails credentials:edit")
        else
          record("credentials.cloudflare.api_token", OK, "set (redacted)")
        end
      end

      def check_api_token
        token = credential(:api_token)
        return record("API token valid", SKIP, "no token to test") if token.to_s.empty?

        response = request("GET", "/user/tokens/verify", token: token)
        if response[:ok] && response[:body].dig("result", "status") == "active"
          record("API token valid", OK, "active (id: #{response[:body].dig('result', 'id')&.slice(0, 8)}...)")
        else
          record("API token valid", FAIL, extract_error(response))
        end
      end

      def check_account_access
        token      = credential(:api_token)
        account_id = credential(:account_id)
        return record("Account accessible", SKIP, "missing token or account_id") if token.to_s.empty? || account_id.to_s.empty?

        response = request("GET", "/accounts/#{account_id}", token: token)
        if response[:ok]
          record("Account accessible", OK, response[:body].dig("result", "name") || account_id)
        elsif response[:status] == 403
          # Send-scoped tokens may lack account read permission. A 403 cannot
          # establish that this token can send for the configured account.
          record("Account accessible", SKIP, "403 — account access unverified; token may lack account read permission")
        else
          record("Account accessible", FAIL, extract_error(response))
        end
      end

      def check_sending_domains
        record("Sending domains", SKIP, "verify your sender domain in Email Sending in the Cloudflare dashboard")
      end

      def check_ingress_secret
        return record("Ingress secret", SKIP, "Cloudflare inbound routing not selected") unless inbound_enabled?
        require "cloudflare/email/credentials"
        secret = Cloudflare::Email::Credentials.ingress_secret

        if secret.empty?
          record("Ingress secret", WARN, "not set — inbound will 401 until you configure it")
        elsif secret.length < 32
          record("Ingress secret", WARN, "set but shorter than 32 chars — rotate to a strong random value")
        else
          record("Ingress secret", OK, "set (#{secret.length} chars)")
        end
      end

      def check_token_split
        return record("Token split", SKIP, "send-only setup; management token optional") unless inbound_enabled?
        require "cloudflare/email/credentials"
        if Cloudflare::Email::Credentials.split_tokens?
          record("Token split", OK, "separate management_token set (good security posture)")
        else
          record("Token split", WARN,
            "single api_token used for runtime + management — consider splitting via CLOUDFLARE_MANAGEMENT_TOKEN " \
            "(see README 'Tokens')")
        end
      end

      def check_action_mailbox_ingress
        return record("ActionMailbox ingress", SKIP, "ActionMailbox not loaded") unless defined?(ActionMailbox)

        case ActionMailbox.ingress
        when :cloudflare
          record("ActionMailbox ingress", OK, ":cloudflare")
        when nil
          record("ActionMailbox ingress", SKIP, "inbound routing not configured")
        else
          record("ActionMailbox ingress", SKIP, "#{ActionMailbox.ingress.inspect} — Cloudflare inbound routing not selected")
        end
      end

      def inbound_enabled?
        defined?(ActionMailbox) && ActionMailbox.respond_to?(:ingress) && ActionMailbox.ingress == :cloudflare
      end

      def check_delivery_method_registered
        return record("Delivery method :cloudflare", SKIP, "ActionMailer not loaded") unless defined?(ActionMailer)

        if ActionMailer::Base.delivery_methods[:cloudflare]
          record("Delivery method :cloudflare", OK, "registered")
        else
          record("Delivery method :cloudflare", FAIL, "not registered — engine failed to load")
        end
      end

      def summary
        @io.puts ""
        width = @results.map { |r| r[:name].length }.max
        @results.each do |r|
          @io.puts "  #{icon(r[:status])}  #{r[:name].ljust(width)}  #{r[:detail]}"
        end
        @io.puts ""

        fail_count = @results.count { |r| r[:status] == FAIL }
        warn_count = @results.count { |r| r[:status] == WARN }

        if fail_count.zero? && warn_count.zero?
          @io.puts "  Completed checks passed. Review skipped checks; live delivery is not verified."
        elsif fail_count.zero?
          @io.puts "  #{warn_count} warning(s). Review warnings and skipped checks before relying on delivery."
        else
          @io.puts "  #{fail_count} failure(s), #{warn_count} warning(s). Fix failures before sending."
        end
        @io.puts ""
      end

      def record(name, status, detail)
        @results << { name: name, status: status, detail: detail }
      end

      def icon(status)
        case status
        when OK   then "[ok]  "
        when WARN then "[warn]"
        when FAIL then "[fail]"
        when SKIP then "[skip]"
        end
      end

      def credential(key)
        require "cloudflare/email/credentials"
        Cloudflare::Email::Credentials.fetch(key)
      end

      def request(method, path, token:)
        uri = URI.parse("https://api.cloudflare.com/client/v4#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 10

        req = (method == "GET" ? Net::HTTP::Get : Net::HTTP::Post).new(uri.request_uri)
        req["Authorization"] = "Bearer #{token}"
        req["Content-Type"]  = "application/json"

        response = http.request(req)
        body = JSON.parse(response.body) rescue {}
        { ok: response.code.to_i.between?(200, 299) && body.is_a?(Hash) && body["success"] != false, status: response.code.to_i, body: body }
      rescue StandardError => e
        { ok: false, status: 0, body: { "errors" => [{ "message" => e.message }] } }
      end

      def extract_error(response)
        errors = response[:body].is_a?(Hash) ? response[:body]["errors"] : nil
        return "HTTP #{response[:status]}" unless errors.is_a?(Array) && errors.any?
        msg = errors.map { |e| e.is_a?(Hash) ? e["message"] : e.to_s }.compact.join("; ")
        "HTTP #{response[:status]} — #{msg}"
      end
    end
  end
end
