require "mailbox_kit/error"

module Cloudflare
  module Email
    Error = MailboxKit::Error
    ConfigurationError = MailboxKit::ConfigurationError
    class AuthenticationError < Error; end
    ValidationError = MailboxKit::ValidationError
    class RateLimitError < Error; end
    class ServerError < Error; end
    class NetworkError < Error; end
  end
end
