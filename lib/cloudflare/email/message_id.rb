# frozen_string_literal: true

module Cloudflare
  module Email
    # Correlation only: a Message-ID does not authorize access to a thread.
    module MessageId
      def self.normalize(value)
        value.to_s.strip.sub(/\A<([^<>]+)>\z/, '\1')
      end
    end
  end
end
