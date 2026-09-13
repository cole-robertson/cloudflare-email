# frozen_string_literal: true

require "net/http"
require "json"
require "timeout"
require "time"
require "digest"
require "cloudflare/email/message_id"

module Cloudflare
  module Email
    # Optional, authenticated, delivered-only evidence. This is not a webhook.
    module RoutingAnalytics
      class Error < StandardError; end

      class Evidence
        attr_reader :payload

        def initialize(payload)
          @payload = JSON.parse(JSON.generate(payload))
          validate!
          freeze_value(@payload)
          freeze
        rescue JSON::ParserError, JSON::GeneratorError, KeyError, ArgumentError, TypeError
          raise Error, "Routing analytics evidence is malformed", cause: nil
        end

        def event = payload.fetch("event")
        def account_id = payload.fetch("account_id")
        def zone_id = payload.fetch("zone_id")
        def message_id = MessageId.normalize(event.fetch("messageId"))
        def occurred_at = Time.iso8601(event.fetch("datetime"))

        def identity
          Digest::SHA256.hexdigest(JSON.generate([account_id, zone_id, event.fetch("sessionId"),
            message_id, occurred_at.iso8601(9), event.fetch("status")]))
        end

        # Query windows change between polls; the authentic row must not change.
        def same_event?(other)
          account_id == other.account_id && zone_id == other.zone_id && event == other.event
        end

        private

        def validate!
          unless payload.is_a?(Hash) && payload["source"] == "cloudflare_routing_analytics" &&
              payload["account_id"].is_a?(String) && !payload["account_id"].empty? &&
              payload["zone_id"].is_a?(String) && payload["zone_id"].match?(/\A[a-f0-9]{32}\z/) &&
              event.is_a?(Hash) && event["eventType"] == "newEmail" && event["status"] == "delivered" &&
              event["isNDR"] == 0 && event["isLastEvent"] == 1 && event["sampleInterval"] == 1 &&
              event["sessionId"].is_a?(String) && !event["sessionId"].strip.empty? &&
              event["from"].is_a?(String) && !event["from"].strip.empty? &&
              event["messageId"].is_a?(String) && !message_id.empty?
            raise Error, "Routing analytics evidence is not an unsampled final delivery"
          end
          start = Time.iso8601(payload.fetch("query_started_at"))
          finish = Time.iso8601(payload.fetch("query_finished_at"))
          unless start <= occurred_at && occurred_at <= finish && finish <= Time.now.utc
            raise Error, "Routing analytics evidence is outside its query window"
          end
          response = payload.fetch("response")
          viewer = response["data"] if response.is_a?(Hash)
          viewer = viewer["viewer"] if viewer.is_a?(Hash)
          zones = viewer["zones"] if viewer.is_a?(Hash)
          unless response.is_a?(Hash) && response["success"] != false &&
              (response["errors"].nil? || response["errors"] == []) && zones.is_a?(Array) && zones.one? &&
              zones.first.is_a?(Hash) && zones.first["zoneTag"] == zone_id
            raise Error, "Routing analytics evidence response has unexpected zone"
          end
          rows = zones.first["emailRoutingAdaptive"]
          unless rows.is_a?(Array) && rows.length < 100 && rows.all? { |row| row.is_a?(Hash) } && rows.include?(event)
            raise Error, "Routing analytics evidence response is malformed or truncated"
          end
        end

        def freeze_value(value)
          value.each { |key, item| freeze_value(key); freeze_value(item) } if value.is_a?(Hash)
          value.each { |item| freeze_value(item) } if value.is_a?(Array)
          value.freeze
        end
      end

      class Client
        REQUEST_TIMEOUT = 5
        MAX_RESPONSE_BYTES = 1_000_000
        QUERY = <<~GRAPHQL.freeze
          query($zone: string!, $ids: [string!], $start: Time!, $finish: Time!) {
            viewer { zones(filter: {zoneTag: $zone}) {
              zoneTag
              emailRoutingAdaptive(limit: 100, orderBy: [datetime_ASC], filter: {
                messageId_in: $ids, datetime_geq: $start, datetime_leq: $finish
              }) { messageId sessionId datetime eventType status isNDR isLastEvent sampleInterval from to action }
            } }
          }
        GRAPHQL

        def initialize(account_id:, zone_id:, api_token:)
          unless account_id.is_a?(String) && !account_id.empty? && zone_id.is_a?(String) &&
              zone_id.match?(/\A[a-f0-9]{32}\z/) && api_token.is_a?(String) && !api_token.strip.empty? &&
              !api_token.match?(/[\r\n]/)
            raise ArgumentError, "Routing analytics requires an account, zone ID and API token"
          end
          @account, @zone, @token = account_id.dup.freeze, zone_id.dup.freeze, api_token.dup.freeze
        end

        def inspect = "#<#{self.class} credentials=[FILTERED]>"

        def verify_account!
          @verified = false
          result = request("/zones/#{@zone}")["result"]
          unless result.is_a?(Hash) && result["id"] == @zone && result["account"].is_a?(Hash) &&
              result["account"]["id"] == @account
            raise Error, "Routing analytics zone/account mismatch"
          end
          @verified = true
        end

        def delivery_evidence(message_id:, since:, until_time:)
          raise Error, "Verify routing analytics zone/account first" unless @verified
          id = MessageId.normalize(message_id)
          unless !id.empty? && since.is_a?(Time) && until_time.is_a?(Time) && since <= until_time && until_time <= Time.now.utc
            raise ArgumentError, "A message ID and valid historical Time window are required"
          end
          # Analytics timestamps have second precision, unlike saved attempts.
          start, finish = Time.at(since.to_i).utc.iso8601, until_time.getutc.iso8601
          data = request("/graphql", query: QUERY, variables: {
            zone: @zone, ids: [id, "<#{id}>"], start: start, finish: finish
          })
          viewer = data["data"]
          viewer = viewer["viewer"] if viewer.is_a?(Hash)
          zones = viewer["zones"] if viewer.is_a?(Hash)
          unless zones.is_a?(Array) && zones.one? && zones.first.is_a?(Hash) && zones.first["zoneTag"] == @zone
            raise Error, "Routing analytics response has unexpected zone"
          end
          rows = zones.first["emailRoutingAdaptive"]
          unless rows.is_a?(Array) && rows.length < 100 && rows.all? { |row| row.is_a?(Hash) }
            raise Error, "Routing analytics response is malformed or truncated"
          end
          final_rows = rows.select { |row| row["eventType"] == "newEmail" && row["isNDR"] == 0 &&
            row["isLastEvent"] == 1 && row["sampleInterval"] == 1 }
          final_rows.group_by { |row| [MessageId.normalize(row["messageId"]), row["sessionId"]] }.each_value do |events|
            if events.uniq.length > 1
              raise Error, "Routing analytics response contains contradictory final events"
            end
          end
          rows.filter_map do |row|
            next unless row["eventType"] == "newEmail" && row["status"] == "delivered" &&
              row["isNDR"] == 0 && row["isLastEvent"] == 1 && row["sampleInterval"] == 1
            evidence = Evidence.new("source" => "cloudflare_routing_analytics", "account_id" => @account,
              "zone_id" => @zone, "query_started_at" => start, "query_finished_at" => finish,
              "response" => data, "event" => row)
            raise Error, "Routing analytics response has unexpected Message-ID" unless evidence.message_id == id
            evidence
          end
        end

        private

        def request(path, body = nil)
          uri = URI("https://api.cloudflare.com/client/v4#{path}")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = http.read_timeout = http.write_timeout = REQUEST_TIMEOUT
          http.max_retries = 0
          request = body ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
          request["Authorization"] = "Bearer #{@token}"
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(body) if body
          payload = +""
          Timeout.timeout(REQUEST_TIMEOUT) do
            http.request(request) do |response|
              raise Error, "Routing analytics HTTP request failed" unless response.is_a?(Net::HTTPSuccess)
              response.read_body do |chunk|
                raise Error, "Routing analytics response is too large" if payload.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES
                payload << chunk
              end
            end
          end
          data = JSON.parse(payload)
          unless data.is_a?(Hash) && data["success"] != false && (data["errors"].nil? || data["errors"] == [])
            raise Error, "Routing analytics API rejected query"
          end
          data
        rescue JSON::ParserError, KeyError, TypeError
          raise Error, "Routing analytics API response is invalid", cause: nil
        rescue Timeout::Error
          raise Error, "Routing analytics HTTP deadline exceeded", cause: nil
        rescue IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError,
            Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError
          raise Error, "Routing analytics HTTP request failed", cause: nil
        end
      end
    end
  end
end
