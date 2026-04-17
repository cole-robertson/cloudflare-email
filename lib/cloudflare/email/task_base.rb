require "cloudflare/email/credentials"

module Cloudflare
  module Email
    # Shared scaffolding for `bin/rails cloudflare:email:*` tasks.
    #
    # Each task subclass implements `#run` (which raises on missing input or
    # returns nil/0 on success). The base class wraps that with consistent
    # credential exposure, error formatting, and exit codes so every task
    # feels the same to the user.
    #
    # Subclasses use `credential(:name)` or the shorthand readers
    # (`account_id`, `api_token`, `management_token`, `ingress_secret`)
    # to pull config. Raising any exception from `#run` is converted to
    # a non-zero exit with a uniformly-formatted error message.
    class TaskBase
      def self.call(**kwargs)
        new(**kwargs).call
      end

      def initialize(io: $stdout, **opts)
        @io   = io
        @opts = opts
      end

      def call
        run
        0
      rescue Cloudflare::Email::Error => e
        @io.puts "  ERROR: #{e.message}"
        @io.puts "  Status: #{e.status}" if e.status
        1
      rescue => e
        @io.puts "  ERROR: #{e.message}"
        1
      end

      protected

      attr_reader :io, :opts

      def say(msg = "")
        @io.puts(msg)
      end

      def credential(key)
        Cloudflare::Email::Credentials.fetch(key)
      end

      def account_id       = Cloudflare::Email::Credentials.account_id
      def api_token        = Cloudflare::Email::Credentials.api_token
      def management_token = Cloudflare::Email::Credentials.management_token
      def ingress_secret   = Cloudflare::Email::Credentials.ingress_secret

      def require_value!(value, label)
        raise ArgumentError, "Missing #{label}" if value.to_s.empty?
        value
      end
    end
  end
end
