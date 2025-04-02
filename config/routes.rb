Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html
  get "/auth/:provider/callback" => "sessions/omni_auths#create", as: :omniauth_callback
  get "/auth/failure" => "sessions/omni_auths#failure", as: :omniauth_failure

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  # root "posts#index"

  namespace :api do
    namespace :v1 do
      resources :users, only: [:index, :create, :show] do
        member do
          get 'top_tracks', to: 'users#user_top_tracks'
          get 'top_artists', to: 'users#user_top_artists'
          get 'compatibility', to: 'users#compatibility'
          get 'profile', to: 'users#show_profile'
        end
        
        collection do
          get 'discover', to: 'users#discover_users'
          get 'music_recommendations', to: 'users#music_recommendations'
        end
      end
      
      resources :friendships, only: [:index, :create, :destroy] do
        collection do
          get 'accepted', to: 'friendships#accepted'
        end
        
        member do
          patch 'accept', to: 'friendships#accept'
          patch 'reject', to: 'friendships#reject'
        end
      end
      
      # Pre-launch signup endpoint
      post '/signups', to: 'signups#create'
      
      # Playlists
      post '/playlists/shared/:user_id', to: 'playlists#create_shared'
    end
  end
end
