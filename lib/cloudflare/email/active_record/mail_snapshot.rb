require "cloudflare/email/active_record/outbox"

module Cloudflare
  module Email
    module ActiveRecord
      class Outbox
        # Render before preparing. Delivery callbacks are intentionally not run:
        # the worker sends the immutable snapshot, never a regenerated mailer.
        def self.prepare_mail(account_id:, operation_key:, mail:)
          mail = mail.message if mail.respond_to?(:message) && !mail.respond_to?(:encoded)
          raise ValidationError, "mail must be a rendered Mail message" unless mail.respond_to?(:encoded)
          if mail.respond_to?(:perform_deliveries) && !mail.perform_deliveries
            raise ValidationError, "email delivery is disabled"
          end

          from = mail.respond_to?(:smtp_envelope_from) ? mail.smtp_envelope_from : Array(mail.from).first
          recipients = mail.respond_to?(:smtp_envelope_to) ? mail.smtp_envelope_to : [mail.to, mail.cc, mail.bcc].flatten.compact
          prepare(account_id: account_id, operation_key: operation_key, from: from,
                  recipients: Array(recipients), mime_message: mail.encoded)
        end
      end
    end
  end
end
