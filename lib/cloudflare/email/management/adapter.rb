module Cloudflare
  module Email
    module Management
      # A host supplies authentication, mailbox ownership and domain entitlement.
      # Defaults deliberately grant no access. No principal comes from params.
      class Adapter
        attr_reader :controller

        def initialize(controller = nil)
          @controller = controller
        end

        def authenticate! = false
        def tenant_key = nil
        def mailboxes(session) = session.mailboxes.none
        def allowed?(action, mailbox = nil) = false
        def domains(session) = []

        # Override these two hooks when the host keeps a linked product model or
        # uses a deployment policy to activate/provision verified addresses.
        def create_mailbox(session, name:, address:)
          session.create(name: name, address: address)
        end

        def add_address(session, mailbox, address:)
          session.add_address(mailbox.id, address: address)
        end
      end
    end
  end
end
