require 'omniauth-oauth2'

module OmniAuth
  module Strategies
    class Spotify < OmniAuth::Strategies::OAuth2
      option :name, 'spotify'
      
      option :client_options, {
        site: 'https://accounts.spotify.com',
        authorize_url: 'https://accounts.spotify.com/authorize',
        token_url: 'https://accounts.spotify.com/api/token'
      }
      
      def info
        @info ||= access_token.get('https://api.spotify.com/v1/me').parsed
      end
      
      # Override the callback URL method to handle dynamic redirect URIs
      def callback_url
        # Check if a custom redirect_uri was provided in the request
        if request.params['redirect_uri']
          # Store the redirect_uri in the session for later use
          session[:omniauth_redirect_uri] = request.params['redirect_uri']
        end
        
        # Use the default callback URL for the OAuth flow
        full_host + script_name + callback_path
      end
    end
  end
end

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :spotify, ENV['SPOTIFY_CLIENT_ID'], ENV['SPOTIFY_CLIENT_SECRET'], 
    scope: 'user-read-email user-read-private user-library-modify user-library-read user-top-read user-read-recently-played user-follow-read user-follow-modify user-read-playback-state user-modify-playback-state user-read-currently-playing app-remote-control streaming user-follow-modify playlist-read-private playlist-read-collaborative playlist-modify-public playlist-modify-private streaming app-remote-control user-read-playback-position user-read-recommendation-seeds user-read-recommendations',
    callback_url: ENV['SPOTIFY_CALLBACK_URL']
end

# Disable CSRF protection for OmniAuth paths
OmniAuth.config.allowed_request_methods = [:post, :get]