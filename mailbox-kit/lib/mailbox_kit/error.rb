module MailboxKit
  class Error < StandardError
    attr_reader :response, :status

    def initialize(message = nil, status: nil, response: nil)
      super(message)
      @status   = status
      @response = response
    end
  end

  class ConfigurationError < Error; end
  class ValidationError < Error; end
end
