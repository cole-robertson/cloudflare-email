require "cloudflare/email/client"

module Cloudflare
  module Email
    # ActionMailer delivery method. Registered on the :cloudflare symbol by the Engine.
    #
    # Configure in your Rails app:
    #
    #   config.action_mailer.delivery_method   = :cloudflare
    #   config.action_mailer.cloudflare_settings = {
    #     account_id: Rails.application.credentials.dig(:cloudflare, :account_id),
    #     api_token:  Rails.application.credentials.dig(:cloudflare, :api_token),
    #   }
    class DeliveryMethod
      attr_accessor :settings

      def initialize(settings = {})
        @settings = settings
      end

      def deliver!(mail)
        client = Cloudflare::Email::Client.new(
          account_id:  settings.fetch(:account_id),
          api_token:   settings.fetch(:api_token),
          base_url:    settings[:base_url] || Cloudflare::Email::Client::DEFAULT_BASE_URL,
          retries:     settings.fetch(:retries,  Cloudflare::Email::Client::DEFAULT_RETRIES),
          timeout:     settings.fetch(:timeout,  Cloudflare::Email::Client::DEFAULT_TIMEOUT),
          logger:      settings[:logger],
        )

        from_addr  = mail.from && mail.from.first
        recipients = collect_recipients(mail)

        raise Cloudflare::Email::ValidationError, "mail has no :from address" if from_addr.nil?
        raise Cloudflare::Email::ValidationError, "mail has no recipients" if recipients.empty?

        response = client.send_raw(
          from:         from_addr,
          recipients:   recipients,
          mime_message: mail.encoded,
        )

        if response.message_id && mail.respond_to?(:message_id=)
          mail.message_id = response.message_id
        end

        response
      end

      private

      def collect_recipients(mail)
        [mail.to, mail.cc, mail.bcc].compact.flatten.uniq
      end
    end
  end
end
