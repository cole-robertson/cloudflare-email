module Cloudflare
  module Email
    module Management
      class Configuration
        attr_accessor :adapter, :back_path
      end

      def self.configuration
        @configuration ||= Configuration.new
      end

      def self.configure
        yield configuration
      end
    end
  end
end
