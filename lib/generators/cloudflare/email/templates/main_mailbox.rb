# Scaffolded by `bin/rails cloudflare:email:install` as the default landing
# place for inbound Cloudflare email. Replace the `process` body with your
# real handling — parse the subject, match the sender, hand off to a job, etc.
#
# See https://guides.rubyonrails.org/action_mailbox_basics.html for the full
# ActionMailbox API (mail is a Mail::Message, inbound_email is the AR record).
class MainMailbox < ApplicationMailbox
  def process
    Rails.logger.info(
      "[cloudflare-email] inbound received: " \
      "from=#{mail.from&.first.inspect} " \
      "to=#{Array(mail.to).inspect} " \
      "subject=#{mail.subject.inspect} " \
      "message_id=#{mail.message_id.inspect}"
    )

    # Example ways to pull content out of the incoming message:
    #
    #   mail.from.first              # => "alice@example.com"
    #   mail.to                      # => ["cole@in.rebulk.com"]
    #   mail.subject                 # => "Re: agent task"
    #   mail.body.decoded            # => "text/plain body, decoded"
    #   mail.html_part&.body&.decoded
    #   mail.attachments             # => [Mail::Part, ...]
    #   inbound_email.message_id     # => "<...@mail.gmail.com>"
    #   inbound_email.raw_email.download  # full RFC822 bytes
    #
    # Common next steps:
    #   YourAgentJob.perform_later(mail.from.first, mail.body.decoded)
    #   bounce_with BounceMailer.not_recognized(inbound_email) if ignore?
  end
end
