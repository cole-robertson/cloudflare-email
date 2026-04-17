module Cloudflare
  module Email
    class Error < StandardError
      attr_reader :response, :status

      def initialize(message = nil, status: nil, response: nil)
        super(message)
        @status   = status
        @response = response
      end
    end

    class ConfigurationError < Error; end
    class AuthenticationError < Error; end
    class ValidationError < Error; end
    class RateLimitError < Error; end
    class ServerError < Error; end
    class NetworkError < Error; end
  end
end
