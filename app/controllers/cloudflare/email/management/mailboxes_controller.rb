module Cloudflare
  module Email
    module Management
      class MailboxesController < ActionController::Base
        layout "layouts/cloudflare/email/management"
        protect_from_forgery with: :exception
        self.forgery_protection_origin_check = true
        around_action :with_host_context
        helper_method :allowed?, :host_back_path

        class Denied < StandardError; end
        class InvalidInput < StandardError; end

        rescue_from Denied do
          head :forbidden
        end
        rescue_from "ActiveRecord::RecordNotFound" do
          head :not_found
        end
        rescue_from InvalidInput, "ActiveRecord::RecordInvalid", Cloudflare::Email::Error do
          redirect_to(@mailbox ? mailbox_path(@mailbox) : root_path,
            alert: "The changes could not be saved. Check the address, registered domain and required fields.",
            status: :see_other)
        end
        rescue_from Cloudflare::Email::ConfigurationError do
          head :service_unavailable
        end

        def index
          authorize!(:index)
          @mailboxes = page(scoped_mailboxes)
          @domains = permitted_domains if allowed?(:create)
        end

        def show
          load_mailbox!(:show)
          @addresses = @session.addresses(@mailbox.id).order(:id).to_a
          @domains = allowed?(:add_address, @mailbox) ? permitted_domains : []
          @messages = allowed?(:show_message, @mailbox) ? page(@session.messages(@mailbox.id)) : []
        end

        def create
          authorize!(:create)
          input = params.require(:mailbox)
          raise InvalidInput unless input.is_a?(ActionController::Parameters)
          values = input.permit(:name, :address)
          name = values[:name].to_s.strip
          raise InvalidInput unless (1..255).cover?(name.length)
          address = permitted_address!(values[:address])
          Mailboxes::Mailbox.transaction do
            @mailbox = @adapter.create_mailbox(@session, name: name, address: address)
            # A hook cannot turn an arbitrary return value into a readable mailbox.
            @mailbox = scoped_mailboxes.find(@mailbox.id)
          end
          redirect_to mailbox_path(@mailbox), notice: "Mailbox created. Review address setup below.", status: :see_other
        end

        def add_address
          load_mailbox!(:add_address)
          @adapter.add_address(@session, @mailbox, address: permitted_address!(params[:address]))
          redirect_to mailbox_path(@mailbox), notice: "Address added. Review its setup status.", status: :see_other
        end

        def suspend
          load_mailbox!(:suspend)
          @session.suspend(@mailbox.id)
          redirect_to mailbox_path(@mailbox), notice: "Mailbox suspended. Messages are retained.", status: :see_other
        end

        def resume
          load_mailbox!(:resume)
          @session.resume(@mailbox.id)
          redirect_to mailbox_path(@mailbox), notice: "Mailbox resumed. Pending addresses still need setup.", status: :see_other
        end

        def message
          load_mailbox!(:show_message)
          @entry = @session.messages(@mailbox.id).find(params[:message_id])
          raw = @session.inbound_email(@mailbox.id, @entry.id).mail
          @subject = raw.subject.to_s
          @from = Array(raw.from).join(", ")
          part = raw.text_part || (raw.mime_type == "text/plain" ? raw : nil)
          @body = part ? part.decoded.to_s.encode("UTF-8", invalid: :replace, undef: :replace).first(100_000) :
            "This message has no plain-text body. HTML rendering is disabled in this management interface."
          @attachments = raw.attachments.map { |attachment| attachment.filename.to_s }
          render :message
        end

        def mark_read
          load_mailbox!(:mark_read)
          @session.mark_read(@mailbox.id, params[:message_id], read: boolean_param(:read))
          redirect_to mailbox_path(@mailbox), status: :see_other
        end

        def archive
          load_mailbox!(:archive)
          @session.archive(@mailbox.id, params[:message_id], archived: boolean_param(:archived))
          redirect_to mailbox_path(@mailbox), status: :see_other
        end

        private

        def with_host_context
          response.headers["Cache-Control"] = "no-store"
          response.headers["Referrer-Policy"] = "same-origin"
          response.headers["X-Content-Type-Options"] = "nosniff"
          response.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'self'; img-src 'none'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
          factory = Management.configuration.adapter
          unless factory.respond_to?(:call) && defined?(Mailboxes) && Mailboxes.enabled?
            return head :service_unavailable
          end
          @adapter = factory.call(self)
          authenticated = @adapter.authenticate!
          return if performed?
          return head :unauthorized unless authenticated == true
          Mailboxes.for_tenant(@adapter.tenant_key) do |session|
            @session = session
            yield
          end
        end

        def allowed?(action, mailbox = nil)
          @adapter.allowed?(action, mailbox) == true
        end

        def authorize!(action, mailbox = nil)
          raise Denied unless allowed?(action, mailbox)
        end

        def scoped_mailboxes
          # Always retain the gem's tenant condition even if a host scope omits it.
          @session.mailboxes.where(id: @adapter.mailboxes(@session).reselect(:id))
        end

        def load_mailbox!(action)
          @mailbox = scoped_mailboxes.find(params[:id])
          authorize!(action, @mailbox)
        end

        def permitted_domains
          granted = Array(@adapter.domains(@session)).map(&:to_s)
          Mailboxes::ReceivingDomain.active.where(tenant_key: @session.tenant_key, domain: granted).order(:domain).pluck(:domain)
        end

        def permitted_address!(value)
          address = Mailboxes.canonical_address(value)
          raise InvalidInput unless permitted_domains.include?(address.split("@", 2).last)
          address
        end

        def page(relation)
          cursor = params[:after].to_s
          raise InvalidInput unless cursor.empty? || cursor.match?(/\A[0-9]{1,18}\z/)
          rows = relation.where("id > ?", cursor.to_i).order(:id).limit(51).to_a
          @next_cursor = rows.length > 50 ? rows[49].id : nil
          rows.first(50)
        end

        def boolean_param(key)
          value = params[key]
          raise InvalidInput unless %w[true false].include?(value)
          value == "true"
        end

        def host_back_path
          callback = Management.configuration.back_path
          value = callback.call(self) if callback.respond_to?(:call)
          value if value.is_a?(String) && value.start_with?("/") && !value.start_with?("//") && !value.match?(/[\\\r\n]/)
        end
      end
    end
  end
end
