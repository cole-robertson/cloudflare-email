require "net/http"
require "json"
require "uri"

module Cloudflare
  module Email
    # Provision Cloudflare Email Routing rules via API — no dashboard clicks.
    #
    # Looks up the zone ID for a domain, enables Email Routing on the zone
    # (publishing the MX + SPF records Cloudflare needs), and creates/updates
    # a rule sending mail for a specific address to a given Worker.
    #
    # Required API token scopes:
    #   Zone → Zone → Read          (to look up zone by name)
    #   Zone → Email Routing → Edit (to enable routing and add rules)
    #
    # Usage:
    #   provisioner = Cloudflare::Email::RoutingProvisioner.new(
    #     api_token: ENV["CLOUDFLARE_API_TOKEN"],
    #   )
    #   provisioner.provision(
    #     address: "cole@in.example.com",
    #     worker_name: "cloudflare-email-ingress-production",
    #   )
    class RoutingProvisioner
      API_BASE = "https://api.cloudflare.com/client/v4".freeze

      def initialize(api_token:, api_base: API_BASE)
        raise ArgumentError, "api_token is required" if api_token.to_s.empty?
        @api_token = api_token
        @api_base  = api_base
      end

      # High-level: given an address + Worker name, do everything needed to
      # make that address route to that Worker. Idempotent — running twice
      # is safe and will update the existing rule rather than duplicate it.
      def provision(address:, worker_name:)
        domain   = extract_domain(address)
        zone_id  = find_zone_id_for(domain)
        raise Error.new("No Cloudflare zone found for #{domain} — add the domain to your account first") unless zone_id

        enable_routing_if_needed(zone_id)
        upsert_route(zone_id: zone_id, address: address, worker_name: worker_name)
      end

      def find_zone_id_for(domain)
        # Try the exact domain, then walk up parent domains until we find a
        # Cloudflare zone. Supports subdomains like "in.example.com" routing
        # to the "example.com" zone.
        candidates = expand_parent_domains(domain)

        candidates.each do |candidate|
          result = api_request(:get, "/zones?name=#{URI.encode_www_form_component(candidate)}")
          zones = Array(result["result"])
          return zones.first["id"] if zones.any?
        end

        nil
      end

      def enable_routing_if_needed(zone_id)
        # This endpoint requires the "Email Routing Settings" permission group,
        # which most scoped tokens don't carry. If we can read the setting,
        # enable when off. If we can't (403), assume the user enabled routing
        # via the dashboard when they added the subdomain — the subsequent
        # rule create will fail with a clear error if not.
        current = raw_api_request(:get, "/zones/#{zone_id}/email/routing")
        status  = current.code.to_i

        case status
        when 200
          body    = parse(current.body)
          enabled = body.dig("result", "enabled")
          api_request(:post, "/zones/#{zone_id}/email/routing/enable") unless enabled
        when 403, 404
          # Either the token can't read settings or routing isn't set up.
          # Try to enable optimistically; ignore failure (rule create will
          # surface a precise error if routing is actually off).
          attempt = raw_api_request(:post, "/zones/#{zone_id}/email/routing/enable")
          # Don't fail here even if this also 403s — move on to rule creation.
        else
          handle!(current, "GET /zones/#{zone_id}/email/routing")
        end
      end

      def upsert_route(zone_id:, address:, worker_name:)
        existing = find_rule_for(zone_id: zone_id, address: address)

        rule = {
          name:     "cloudflare-email gem — #{address}",
          enabled:  true,
          priority: 0,
          matchers: [{ field: "to", type: "literal", value: address }],
          actions:  [{ type: "worker", value: [worker_name] }],
        }

        if existing
          api_request(
            :put,
            "/zones/#{zone_id}/email/routing/rules/#{existing['id']}",
            body: rule,
          )
        else
          api_request(
            :post,
            "/zones/#{zone_id}/email/routing/rules",
            body: rule,
          )
        end
      end

      def find_rule_for(zone_id:, address:)
        result = api_request(:get, "/zones/#{zone_id}/email/routing/rules?per_page=50")
        rules  = Array(result["result"])

        rules.find do |r|
          matchers = Array(r["matchers"])
          matchers.any? { |m| m["field"] == "to" && m["value"] == address }
        end
      end

      def list_rules(zone_id)
        result = api_request(:get, "/zones/#{zone_id}/email/routing/rules?per_page=50")
        Array(result["result"])
      end

      private

      def extract_domain(address)
        if address.include?("@")
          address.split("@", 2).last
        else
          address
        end
      end

      # "a.b.c.example.com" → ["a.b.c.example.com", "b.c.example.com", "c.example.com", "example.com"]
      def expand_parent_domains(domain)
        parts = domain.split(".")
        return [domain] if parts.size < 2
        (0..(parts.size - 2)).map { |i| parts[i..].join(".") }
      end

      def api_request(method, path, body: nil)
        response = raw_api_request(method, path, body: body)
        handle!(response, "#{method.upcase} #{path}")
        parse(response.body)
      end

      def raw_api_request(method, path, body: nil)
        uri  = URI.parse("#{@api_base}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 30
        http.read_timeout = 60

        klass = {
          get:    Net::HTTP::Get,
          post:   Net::HTTP::Post,
          put:    Net::HTTP::Put,
          delete: Net::HTTP::Delete,
        }.fetch(method)

        req = klass.new(uri.request_uri)
        req["Authorization"] = "Bearer #{@api_token}"
        req["Accept"]        = "application/json"
        req["Content-Type"]  = "application/json" if body
        req.body             = JSON.generate(body) if body

        http.request(req)
      end

      def handle!(response, context)
        status = response.code.to_i
        return if status.between?(200, 299)

        body    = parse(response.body)
        errors  = body.is_a?(Hash) ? Array(body["errors"]) : []
        message = errors.map { |e| e.is_a?(Hash) ? e["message"] : e.to_s }.compact.join("; ")
        message = "HTTP #{status}" if message.empty?

        raise Error.new(
          "[routing_provisioner] #{context} failed: #{message}",
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
