require "net/http"
require "json"
require "uri"

module Cloudflare
  module Email
    # Provision Cloudflare Email Routing rules via API.
    #
    # Looks up the zone ID for a domain, enables Email Routing on the zone
    # (publishing the MX + SPF records Cloudflare needs), and creates/updates
    # a rule sending mail for a specific address to a given Worker.
    #
    # Required API token scopes:
    #   Zone → Zone → Read          (to look up zone by name)
    #   Zone → Email Routing → Edit (to enable routing and add rules)
    #   Zone → DNS → Read           (to check preconfigured subdomains)
    #   Zone → Zone Settings → Edit (to enable apex routing)
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
        zone = find_zone_for(domain)
        raise Error.new("No Cloudflare zone found for #{domain} — add the domain to your account first") unless zone

        if zone["name"] == domain
          enable_routing_if_needed(zone["id"])
        else
          check_subdomain_dns!(zone_id: zone["id"], domain: domain)
        end
        upsert_route(zone_id: zone["id"], address: address, worker_name: worker_name)
      end

      def find_zone_id_for(domain)
        find_zone_for(domain)&.fetch("id")
      end

      def find_zone_for(domain)
        # Try the exact domain, then walk up parent domains until we find a
        # Cloudflare zone. Supports subdomains like "in.example.com" routing
        # to the "example.com" zone.
        candidates = expand_parent_domains(domain)

        candidates.each do |candidate|
          result = api_request(:get, "/zones?name=#{URI.encode_www_form_component(candidate)}")
          zones = Array(result["result"])
          return zones.first.merge("name" => candidate) if zones.any?
        end

        nil
      end

      def enable_routing_if_needed(zone_id)
        current = api_request(:get, "/zones/#{zone_id}/email/routing")
        unless [true, false].include?(current.dig("result", "enabled"))
          raise Error.new("Email Routing settings response did not include an enabled flag; no routing settings were changed")
        end
        return if current.dig("result", "enabled") == true

        api_request(:post, "/zones/#{zone_id}/email/routing/dns")
      end

      # Cloudflare's documented subdomain onboarding is dashboard-only. Check
      # its DNS prerequisites without ever modifying the parent zone's routing.
      # This checks configured records, not propagation or live delivery.
      def check_subdomain_dns!(zone_id:, domain:)
        records = paginated_results("/zones/#{zone_id}/dns_records?name=#{URI.encode_www_form_component(domain)}")
        mx = records.select { |r| r["type"] == "MX" }.map { |r| r["content"].to_s.downcase.delete_suffix(".") }.uniq.sort
        expected_mx = (1..3).map { |n| "route#{n}.mx.cloudflare.net" }
        spf = records.select { |r| r["type"] == "TXT" }.map { |r| r["content"].to_s.delete('"') }.select { |v| v.start_with?("v=spf1 ") }
        return if mx == expected_mx && spf.size == 1 && spf.first.split.include?("include:_spf.mx.cloudflare.net")

        raise Error.new("Email Routing DNS for #{domain} is missing or conflicts with another mail provider. " \
          "In Cloudflare, open Email Routing > the apex domain > Settings > Subdomains and onboard #{domain}; " \
          "then retry after checking its routing MX and SPF records. Parent-zone routing was not changed.")
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
        list_rules(zone_id).find do |r|
          matchers = Array(r["matchers"])
          matchers.size == 1 && matchers.any? { |m| m["field"] == "to" && m["type"] == "literal" && m["value"] == address }
        end
      end

      def list_rules(zone_id)
        paginated_results("/zones/#{zone_id}/email/routing/rules")
      end

      # Point the zone's catch-all rule at our Worker. Catch-all matches any
      # address on the zone that isn't covered by a more specific rule.
      # Useful for bounce handling, dev subdomains, alias routing.
      def provision_catch_all(zone_id:, worker_name:)
        api_request(
          :put,
          "/zones/#{zone_id}/email/routing/rules/catch_all",
          body: {
            name:     "cloudflare-email gem — catch-all",
            enabled:  true,
            matchers: [{ type: "all" }],
            actions:  [{ type: "worker", value: [worker_name] }],
          },
        )
      end

      def provision_catch_all_for_domain(domain:, worker_name:)
        domain = domain.to_s.downcase.delete_suffix(".")
        zone = find_zone_for(domain)
        raise Error.new("No Cloudflare zone found for #{domain}") unless zone
        unless zone["name"] == domain
          raise Error.new("Catch-all rules are zone-wide: #{domain} belongs to zone #{zone['name']}. " \
            "This task cannot scope a catch-all to a subdomain. Use explicit address routes or configure subdomain handling in the dashboard.")
        end

        enable_routing_if_needed(zone["id"])
        provision_catch_all(zone_id: zone["id"], worker_name: worker_name)
      end

      private

      def paginated_results(path)
        records = []
        page = 1
        loop do
          separator = path.include?("?") ? "&" : "?"
          result = api_request(:get, "#{path}#{separator}per_page=50&page=#{page}")
          batch = Array(result["result"])
          records.concat(batch)
          total_pages = result.dig("result_info", "total_pages")
          break if batch.empty? || (total_pages ? page >= total_pages.to_i : batch.size < 50)
          page += 1
        end
        records
      end

      def extract_domain(address)
        unless address.to_s.match?(/\A[^\s@]+@[^\s@]+\z/)
          raise ArgumentError, "address must be a full email address"
        end
        address.split("@", 2).last.downcase.delete_suffix(".")
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
        body    = parse(response.body)
        return if status.between?(200, 299) && body.is_a?(Hash) && body["success"] != false && body.key?("result")

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
