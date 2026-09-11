require "net/http"
require "json"
require "uri"
require "timeout"
require "cloudflare/email/endpoint"

module Cloudflare
  module Email
    # A bounded, GET-only snapshot of provider configuration. This deliberately
    # does not inherit RoutingProvisioner: inspecting must never repair routing.
    class RoutingDiagnostics
      API_BASE = "https://api.cloudflare.com/client/v4".freeze
      MAX_BYTES = 1_048_576
      MAX_PAGES = 50
      LIMITATIONS = "Configuration snapshot only: does not prove public DNS propagation, live delivery, Worker destination, or application acceptance.".freeze
      class ReadError < StandardError; end

      def initialize(api_token:, api_base: API_BASE)
        raise ArgumentError, "api_token is required" if api_token.to_s.empty?
        @api_token = api_token
        @api_base = Endpoint.parse(api_base).to_s.delete_suffix("/")
      end

      # Status is pass only if every requested configuration check passes.
      # Unknown means inspection could not establish readiness, not success.
      def check(address:, worker_name:, account_id: nil)
        unless address.is_a?(String) && address.bytesize <= 254 && address.match?(/\A[^\s@]+@(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z0-9-]+\z/)
          raise ArgumentError, "address must be a full email address with a DNS domain"
        end
        raise ArgumentError, "worker_name is required" if worker_name.to_s.empty?
        domain = address.split("@", 2).last.downcase
        address = "#{address.split('@', 2).first}@#{domain}"
        checks = []
        zone = inspect_check(checks, "zone") { find_zone(domain) }
        if zone
          if account_id
            actual = zone["account"].is_a?(Hash) ? zone["account"]["id"] : nil
            add(checks, "account", actual.nil? ? "unknown" : (actual == account_id ? "pass" : "fail"),
              actual.nil? ? "Zone account was not returned." : (actual == account_id ? "Zone belongs to the expected account." : "Zone belongs to a different account."))
          end
          zone_id = URI.encode_www_form_component(zone.fetch("id"))
          inspect_check(checks, "routing") { routing_check(checks, zone_id) }
          inspect_check(checks, "dns") { dns_check(checks, zone_id, domain) }
          inspect_check(checks, "route") { route_check(checks, zone_id, address, worker_name) }
        else
          %w[routing dns route].each { |name| add(checks, name, "unknown", "Cannot inspect without a unique zone.") }
        end
        statuses = checks.map { |item| item[:status] }
        { status: statuses.include?("fail") ? "fail" : (statuses.include?("unknown") ? "unknown" : "pass"),
          checks: checks, limitations: LIMITATIONS }
      end

      private

      def add(checks, name, status, message)
        checks << { name: name, status: status, message: message }
      end

      def inspect_check(checks, name)
        value = yield
        add(checks, name, "pass", "Found a unique containing Cloudflare zone.") if name == "zone" && value
        add(checks, name, "fail", "No containing Cloudflare zone was found.") if name == "zone" && !value
        value
      rescue ReadError => e
        add(checks, name, "unknown", e.message)
        nil
      rescue StandardError
        add(checks, name, "unknown", "Provider configuration could not be interpreted safely.")
        nil
      end

      def find_zone(domain)
        parts = domain.split(".")
        (0..parts.size - 2).each do |index|
          candidate = parts[index..].join(".")
          zones = pages("/zones?name=#{URI.encode_www_form_component(candidate)}")
          next if zones.empty?
          unless zones.size == 1 && zones.first["name"].to_s.downcase == candidate && zones.first["id"].is_a?(String)
            raise ReadError, "Zone lookup was ambiguous or incomplete."
          end
          return zones.first
        end
        nil
      end

      def routing_check(checks, zone_id)
        result = get("/zones/#{zone_id}/email/routing")["result"]
        enabled = result.is_a?(Hash) ? result["enabled"] : nil
        status = enabled == true ? "pass" : (enabled == false ? "fail" : "unknown")
        add(checks, "routing", status, enabled == true ? "Zone Email Routing is enabled." : "Zone Email Routing is disabled or its enabled flag is unavailable.")
      end

      def dns_check(checks, zone_id, domain)
        records = pages("/zones/#{zone_id}/dns_records?name=#{URI.encode_www_form_component(domain)}")
        # Defensively enforce exact name even when the provider returns parent
        # records. A parent's Google MX must not invalidate a receiving subdomain.
        records = records.select { |record| record["name"].to_s.downcase.delete_suffix(".") == domain }
        mx = records.select { |r| r["type"] == "MX" }.map { |r| r["content"].to_s.downcase.delete_suffix(".") }.uniq.sort
        spf = records.select { |r| r["type"] == "TXT" }.map { |r| r["content"].to_s.delete('"') }.select { |v| v.match?(/\Av=spf1(?:\s|\z)/i) }
        mx_ok = mx == (1..3).map { |n| "route#{n}.mx.cloudflare.net" }
        # Do not declare an include useful when an earlier `all` terminates SPF.
        terms = spf.size == 1 ? spf.first.split.drop(1) : []
        include_index = terms.index("include:_spf.mx.cloudflare.net")
        all_index = terms.index { |term| term.match?(/\A[+~?-]?all\z/i) }
        spf_ok = include_index && (!all_index || include_index < all_index)
        add(checks, "dns", mx_ok && spf_ok ? "pass" : "fail", mx_ok && spf_ok ?
          "Exact receiving domain has Cloudflare MX records and one SPF record including Cloudflare." :
          "Exact receiving domain needs Cloudflare MX records and a single SPF record with an effective Cloudflare include; records may be missing or conflicting.")
      end

      def route_check(checks, zone_id, address, worker_name)
        rules = pages("/zones/#{zone_id}/email/routing/rules")
        matching = []
        rules.each do |rule|
          next if rule["enabled"] == false
          matchers = rule["matchers"]
          unless matchers.is_a?(Array) && matchers.size == 1 && matchers.first.is_a?(Hash)
            raise ReadError, "Unsupported rule matchers prevent establishing which rule wins."
          end
          matcher = matchers.first
          unless matcher["type"] == "literal" && matcher["field"] == "to" && matcher["value"].is_a?(String)
            raise ReadError, "Unsupported rule matchers prevent establishing which rule wins."
          end
          next unless matcher["value"].casecmp?(address)
          raise ReadError, "A matching rule has an unknown enabled state." unless rule["enabled"] == true
          matching << rule
        end
        if matching.size > 1
          raise ReadError, "Multiple explicit rules match; their priority or tie ordering has not been verified."
        end
        if matching.one?
          selected = matching.first
          source = "Explicit address rule (takes precedence over catch-all)"
        else
          selected = get("/zones/#{zone_id}/email/routing/rules/catch_all")["result"]
          unless selected.is_a?(Hash) && selected["matchers"] == [{ "type" => "all" }]
            raise ReadError, "Catch-all settings are incomplete or use unsupported matchers."
          end
          source = "Catch-all rule"
        end
        unless [true, false].include?(selected["enabled"])
          raise ReadError, "Selected rule has an unknown enabled state."
        end
        unless selected["enabled"]
          return add(checks, "route", "fail", "No enabled explicit route or catch-all accepts this address.")
        end
        actions = selected["actions"]
        unless actions.is_a?(Array) && actions.all? { |action| action.is_a?(Hash) }
          raise ReadError, "Selected rule actions were not returned."
        end
        correct = actions.size == 1 && actions.first["type"] == "worker" && actions.first["value"] == [worker_name]
        add(checks, "route", correct ? "pass" : "fail", correct ?
          "#{source} targets the expected Worker." : "#{source} does not exclusively target the expected Worker (it may drop, forward, or target another Worker).")
      end

      def pages(path)
        records = []
        1.upto(MAX_PAGES) do |page|
          data = get("#{path}#{path.include?('?') ? '&' : '?'}per_page=50&page=#{page}")
          batch = data["result"]
          raise ReadError, "Provider returned an invalid list." unless batch.is_a?(Array) && batch.all? { |item| item.is_a?(Hash) }
          records.concat(batch)
          total = data.dig("result_info", "total_pages")
          if total && (!total.is_a?(Integer) || total.negative? || (total.zero? && batch.any?))
            raise ReadError, "Provider returned invalid pagination."
          end
          return records if total ? page >= total : batch.size < 50
          raise ReadError, "Provider pagination ended before all pages were available." if batch.empty?
        end
        raise ReadError, "Provider pagination exceeds the inspection limit."
      end

      def get(path)
        uri = URI.parse("#{@api_base}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 5
        http.read_timeout = 10
        request = Net::HTTP::Get.new(uri.request_uri)
        request["Authorization"] = "Bearer #{@api_token}"
        request["Accept"] = "application/json"
        body = +""
        # read_timeout alone does not bound a peer streaming tiny chunks.
        Timeout.timeout(20) do
          http.request(request) do |response|
            raise ReadError, "Provider request failed (HTTP #{response.code.to_i}); check token scopes and configuration." unless response.code.to_i.between?(200, 299)
            response.read_body do |chunk|
              raise ReadError, "Provider response exceeds the inspection size limit." if body.bytesize + chunk.bytesize > MAX_BYTES
              body << chunk
            end
          end
        end
        data = JSON.parse(body)
        unless data.is_a?(Hash) && data["success"] == true && data.key?("result")
          raise ReadError, "Provider response did not contain a successful result."
        end
        data
      rescue ReadError
        raise
      rescue StandardError
        # Never surface raw provider bodies, URLs, credentials, or socket errors.
        raise ReadError, "Provider request could not be read; check connectivity, token scopes, and response format."
      end
    end
  end
end
