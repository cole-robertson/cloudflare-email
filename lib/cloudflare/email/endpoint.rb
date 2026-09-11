require "uri"
require "cloudflare/email/error"

module Cloudflare
  module Email
    # Endpoints are trusted operator configuration, never message-derived URLs.
    # Plain HTTP is only suitable for literal loopback development fixtures.
    module Endpoint
      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

      def self.parse(value, allow_loopback: true)
        uri = URI.parse(value.to_s)
        secure = uri.is_a?(URI::HTTPS)
        local = allow_loopback && uri.is_a?(URI::HTTP) && LOOPBACK_HOSTS.include?(uri.hostname.to_s.downcase)
        unless (secure || local) && !uri.hostname.to_s.empty? && !uri.userinfo && !uri.query && !uri.fragment
          raise ConfigurationError, "endpoint must use HTTPS (HTTP only on literal loopback), without credentials, query or fragment"
        end
        uri
      rescue URI::InvalidURIError
        raise ConfigurationError, "endpoint must be a valid HTTPS URL"
      end
    end
  end
end
