module MailboxKit
  module AddressSyntax
      LOCAL_PART = /\A[A-Za-z0-9.!#$%&'*+\/=\?^_`{|}~-]+\z/
      DOMAIN_LABEL = /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/

      def self.valid_address?(address, allow_empty: false)
        return false unless address.is_a?(String) && address.ascii_only?
        return true if allow_empty && address.empty?
        return false if address.bytesize > 254
        parts = address.split("@", -1)
        return false unless parts.size == 2
        local, domain = parts
        local.bytesize <= 64 && LOCAL_PART.match?(local) &&
          !local.start_with?(".") && !local.end_with?(".") && !local.include?("..") &&
          domain.split(".", -1).all? { |label| DOMAIN_LABEL.match?(label) }
      end

  end
end
