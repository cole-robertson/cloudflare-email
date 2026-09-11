Cloudflare::Email::Management::Engine.routes.draw do
  get "style.css", to: "styles#show", as: :style
  root to: "mailboxes#index"
  resources :mailboxes, only: [:index, :show, :create] do
    member do
      post :aliases, action: :add_address
      post :suspend
      post :resume
      get "messages/:message_id", action: :message, as: :message
      post :mark_read
      post :archive
    end
  end
end
