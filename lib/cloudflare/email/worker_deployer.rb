require "net/http"
require "json"
require "securerandom"

module Cloudflare
  module Email
    # Deploys and manages the shipped Cloudflare Email Worker via the
    # Cloudflare API directly — no wrangler, no Node, no npm required.
    #
    # Required API token scopes:
    #   Account → Workers Scripts → Edit
    #
    # Usage:
    #   deployer = Cloudflare::Email::WorkerDeployer.new(
    #     account_id: ..., api_token: ...,
    #   )
    #   deployer.deploy(script_path: "cloudflare-worker/src/index.js")
    #   deployer.put_secret("INGRESS_SECRET", "...")
    #   deployer.put_secret("RAILS_INGRESS_URL", "https://...")
    class WorkerDeployer
      DEFAULT_SCRIPT_NAME        = "cloudflare-email-ingress".freeze
      DEFAULT_COMPATIBILITY_DATE = "2026-04-01".freeze
      API_BASE                   = "https://api.cloudflare.com/client/v4".freeze

      attr_reader :script_name

      def initialize(account_id:, api_token:,
                     script_name: DEFAULT_SCRIPT_NAME,
                     compatibility_date: DEFAULT_COMPATIBILITY_DATE,
                     api_base: API_BASE)
        raise ArgumentError, "account_id is required" if account_id.to_s.empty?
        raise ArgumentError, "api_token is required"  if api_token.to_s.empty?

        @account_id         = account_id
        @api_token          = api_token
        @script_name        = script_name
        @compatibility_date = compatibility_date
        @api_base           = api_base
      end

      # Uploads/updates the Worker script. Accepts either `script_path:` (a
      # path to a .js file) or `source:` (the JS source string directly).
      def deploy(script_path: nil, source: nil)
        source ||= File.read(script_path) if script_path
        raise ArgumentError, "must pass script_path: or source:" if source.nil?

        boundary = "----cf-email-#{SecureRandom.hex(16)}"
        body     = build_multipart(boundary, source)

        request(
          method: :put,
          path:   "/accounts/#{@account_id}/workers/scripts/#{@script_name}",
          body:   body,
          content_type: "multipart/form-data; boundary=#{boundary}",
        )
      end

      # Set/update a Worker secret.
      def put_secret(name, value)
        request(
          method: :put,
          path:   "/accounts/#{@account_id}/workers/scripts/#{@script_name}/secrets",
          body:   JSON.generate({ name: name.to_s, text: value.to_s, type: "secret_text" }),
          content_type: "application/json",
        )
      end

      # Delete a Worker secret by name.
      def delete_secret(name)
        request(
          method: :delete,
          path:   "/accounts/#{@account_id}/workers/scripts/#{@script_name}/secrets/#{name}",
        )
      end

      # True if the Worker script already exists.
      def exists?
        response = raw_request(
          method: :get,
          path:   "/accounts/#{@account_id}/workers/scripts/#{@script_name}",
        )
        response.code.to_i == 200
      end

      # Delete the Worker. Useful for teardown in tests.
      def delete_script
        request(
          method: :delete,
          path:   "/accounts/#{@account_id}/workers/scripts/#{@script_name}",
        )
      end

      private

      def build_multipart(boundary, source)
        metadata = JSON.generate({
          main_module:        "index.js",
          compatibility_date: @compatibility_date,
        })

        parts = []
        parts << "--#{boundary}"
        parts << 'Content-Disposition: form-data; name="metadata"'
        parts << "Content-Type: application/json"
        parts << ""
        parts << metadata
        parts << "--#{boundary}"
        parts << 'Content-Disposition: form-data; name="index.js"; filename="index.js"'
        parts << "Content-Type: application/javascript+module"
        parts << ""
        parts << source
        parts << "--#{boundary}--"
        # Force binary to avoid encoding-driven header injection by Net::HTTP.
        (parts.join("\r\n") + "\r\n").force_encoding(Encoding::ASCII_8BIT)
      end

      def request(method:, path:, body: nil, content_type: "application/json")
        response = raw_request(method: method, path: path, body: body, content_type: content_type)
        handle(response, "#{method.upcase} #{path}")
      end

      def raw_request(method:, path:, body: nil, content_type: "application/json")
        uri = URI.parse("#{@api_base}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl     = uri.scheme == "https"
        http.open_timeout = 30
        http.read_timeout = 60

        klass = {
          put:    Net::HTTP::Put,
          post:   Net::HTTP::Post,
          get:    Net::HTTP::Get,
          delete: Net::HTTP::Delete,
        }.fetch(method)

        req = klass.new(uri.request_uri)
        req["Authorization"] = "Bearer #{@api_token}"
        req["Accept"]        = "application/json"
        req["Content-Type"]  = content_type if body
        req.body             = body if body

        http.request(req)
      end

      def handle(response, context)
        status = response.code.to_i
        body   = parse(response.body)

        return body if status.between?(200, 299)

        errors  = body.is_a?(Hash) ? Array(body["errors"]) : []
        message = errors.map { |e| e.is_a?(Hash) ? e["message"] : e.to_s }.compact.join("; ")
        message = "HTTP #{status}" if message.empty?

        raise Error.new(
          "[worker_deployer] #{context} failed: #{message}",
          status: status, response: body,
        )
      end

      def parse(body)
        return {} if body.nil? || body.empty?
        JSON.parse(body)
      rescue JSON::ParserError
        { "errors" => [{ "message" => body.to_s[0, 200] }] }
      end
    end
  end
end
