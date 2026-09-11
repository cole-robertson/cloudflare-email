require "net/http"
require "json"
require "uri"
require "time"
require "cloudflare/email/endpoint"

module Cloudflare
  module Email
    class Client
      DEFAULT_BASE_URL = "https://api.cloudflare.com/client/v4".freeze
      DEFAULT_RETRIES  = 3
      DEFAULT_TIMEOUT  = 30
      DEFAULT_BACKOFF  = 0.5
      MAX_RETRY_AFTER  = 60 # seconds; never sleep longer than this even if server says so

      RETRYABLE_NETWORK = [
        Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Errno::ECONNRESET,
        Errno::ECONNREFUSED, Errno::EHOSTUNREACH, EOFError, SocketError,
        IOError
      ].freeze
      PRE_SEND_NETWORK = [Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError].freeze

      attr_reader :account_id, :base_url, :retries, :timeout, :retry_ambiguous

      def initialize(account_id:, api_token:, base_url: DEFAULT_BASE_URL,
                     retries: DEFAULT_RETRIES, timeout: DEFAULT_TIMEOUT,
                     initial_backoff: DEFAULT_BACKOFF, max_retry_after: MAX_RETRY_AFTER,
                     retry_ambiguous: false, logger: nil)
        unless account_id.is_a?(String) && account_id.match?(/\A[a-zA-Z0-9_-]+\z/)
          raise ConfigurationError, "account_id is required and must be a single account identifier"
        end
        unless api_token.is_a?(String) && !api_token.empty? && !api_token.match?(/\s/)
          raise ConfigurationError, "api_token is required and must not contain whitespace"
        end

        @account_id      = account_id
        @api_token       = api_token
        @base_url        = Endpoint.parse(base_url).to_s.delete_suffix("/")
        @retries         = retries
        @timeout         = timeout
        @initial_backoff = initial_backoff
        @max_retry_after = max_retry_after
        @logger          = logger
        @retry_ambiguous = retry_ambiguous
      end

      def inspect
        "#<#{self.class.name} account_id=#{@account_id.inspect} api_token=[REDACTED]>"
      end

      def send(from:, subject:, to: nil, text: nil, html: nil, cc: nil, bcc: nil,
               reply_to: nil, headers: nil, attachments: nil)
        raise ValidationError, "must provide :text or :html" if text.nil? && html.nil?
        raise ValidationError, "must provide a recipient in :to, :cc, or :bcc" if [to, cc, bcc].all? { |v| wrap(v).empty? }

        body = {
          from:    normalize_address(from),
          subject: subject,
        }
        body[:to]          = wrap(to).map { |addr| normalize_address(addr) } if to
        body[:text]        = text if text
        body[:html]        = html if html
        body[:cc]          = wrap(cc).map  { |a| normalize_address(a) } if cc
        body[:bcc]         = wrap(bcc).map { |a| normalize_address(a) } if bcc
        body[:reply_to]    = normalize_address(reply_to) if reply_to
        body[:headers]     = headers if headers
        body[:attachments] = attachments if attachments

        perform(:send, "/accounts/#{@account_id}/email/sending/send", body)
      end

      def send_raw(from:, recipients:, mime_message:)
        body = {
          from:         extract_address(from),
          recipients:   wrap(recipients).map { |r| extract_address(r) },
          mime_message: mime_message,
        }
        perform(:send_raw, "/accounts/#{@account_id}/email/sending/send_raw", body)
      end

      private

      # Wrap a value into an array without Hash-to-pair-array conversion.
      def wrap(value)
        case value
        when Array then value
        when nil   then []
        else [value]
        end
      end

      def normalize_address(addr)
        case addr
        when String
          addr
        when Hash
          h = { address: addr[:address] || addr["address"] }
          name = addr[:name] || addr["name"]
          h[:name] = name if name
          raise ValidationError, "address hash requires :address" unless h[:address]
          h
        else
          raise ValidationError, "address must be a String or Hash, got #{addr.class}"
        end
      end

      def extract_address(addr)
        case addr
        when String then addr
        when Hash   then addr[:address] || addr["address"] || raise(ValidationError, "address hash requires :address")
        else raise ValidationError, "address must be a String or Hash, got #{addr.class}"
        end
      end

      def perform(operation, path, body)
        instrument("cloudflare_email.#{operation}", account_id: @account_id, path: path) do |payload|
          response = request(:post, path, body)
          payload[:status]     = response.status
          payload[:message_id] = response.message_id
          payload[:delivered] = response.delivered
          payload[:queued] = response.queued
          payload[:permanent_bounces] = response.permanent_bounces
          payload[:suppressed_recipients] = response.suppressed_recipients
          response
        end
      end

      def instrument(name, payload)
        if defined?(ActiveSupport::Notifications)
          ActiveSupport::Notifications.instrument(name, payload) { |p| yield p }
        else
          yield payload
        end
      end

      def request(method, path, body)
        uri = URI.parse("#{@base_url}#{path}")
        attempts = 0
        backoff  = @initial_backoff

        begin
          attempts += 1
          do_request(method, uri, body)
        rescue *RETRYABLE_NETWORK => e
          unless PRE_SEND_NETWORK.any? { |type| e.is_a?(type) } || @retry_ambiguous
            raise NetworkError.new("#{e.message}; delivery outcome is unknown; automatic retry disabled")
          end
          raise NetworkError.new(e.message) if attempts > @retries
          log_retry(attempts, e)
          sleep(backoff); backoff *= 2
          retry
        rescue RateLimitError => e
          raise if attempts > @retries
          log_retry(attempts, e)
          sleep(retry_after_from(e, backoff)); backoff *= 2
          retry
        rescue ServerError => e
          raise unless @retry_ambiguous && attempts <= @retries
          log_retry(attempts, e)
          sleep(backoff); backoff *= 2
          retry
        end
      end

      def retry_after_from(error, fallback_backoff)
        header = error.response.is_a?(Hash) ? error.response["retry_after"] : nil
        value  = header || fallback_backoff
        seconds = if value.to_s.match?(/\A\d+(?:\.\d+)?\z/)
          value.to_f
        else
          begin
            Time.httpdate(value.to_s) - Time.now
          rescue ArgumentError
            fallback_backoff
          end
        end
        return fallback_backoff if seconds <= 0
        [seconds, @max_retry_after].min
      end

      def do_request(method, uri, body)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl     = (uri.scheme == "https")
        http.open_timeout = @timeout
        http.read_timeout = @timeout
        http.write_timeout = @timeout
        http.max_retries = 0

        req_class = { post: Net::HTTP::Post, get: Net::HTTP::Get }.fetch(method)
        req = req_class.new(uri.request_uri)
        req["Authorization"] = "Bearer #{@api_token}"
        req["Content-Type"]  = "application/json"
        req["Accept"]        = "application/json"
        req["User-Agent"]    = "cloudflare-email-ruby/#{Cloudflare::Email::VERSION}"
        req.body = JSON.generate(body) if body

        response = http.request(req)
        handle_response(response)
      end

      def handle_response(response)
        status  = response.code.to_i
        body    = parse_body(response.body)
        retry_after = response["Retry-After"]

        # Stash Retry-After on the error response so retry logic can use it.
        body = body.merge("retry_after" => retry_after) if body.is_a?(Hash) && retry_after

        case status
        when 200..299
          if body.is_a?(Hash) && body.key?("success") && body["success"] != true
            raise Error.new(extract_message(body), status: status, response: body)
          end
          unless body.is_a?(Hash) && body["result"].is_a?(Hash)
            raise Error.new("invalid successful API response; request outcome is unknown", status: status, response: body)
          end
          if body["errors"].is_a?(Array) && body["errors"].any?
            raise Error.new(extract_message(body), status: status, response: body)
          end
          Response.new(body, status: status)
        when 400, 422
          raise ValidationError.new(extract_message(body), status: status, response: body)
        when 401, 403
          raise AuthenticationError.new(extract_message(body), status: status, response: body)
        when 429
          raise RateLimitError.new(extract_message(body), status: status, response: body)
        when 500..599
          raise ServerError.new(extract_message(body), status: status, response: body)
        else
          raise Error.new("unexpected status #{status}: #{extract_message(body)}",
                          status: status, response: body)
        end
      end

      def parse_body(raw)
        return {} if raw.nil? || raw.empty?
        JSON.parse(raw)
      rescue JSON::ParserError
        { "errors" => [{ "message" => raw.to_s[0, 200] }] }
      end

      def extract_message(body)
        return "unknown error" unless body.is_a?(Hash)
        errors = body["errors"]
        return "unknown error" unless errors.is_a?(Array) && errors.any?
        errors.map { |e| e.is_a?(Hash) ? e["message"] : e.to_s }.compact.join("; ")
      end

      def log_retry(attempt, error)
        return unless @logger
        # Provider messages can echo message content or other sensitive data.
        @logger.warn("[cloudflare-email] retry #{attempt}: #{error.class}")
      end
    end
  end
end
