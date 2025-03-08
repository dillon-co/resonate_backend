# Rails.application.config.middleware.use OmniAuth::Builder do
#     provider :spotify, ENV['SPOTIFY_CLIENT_ID'], ENV['SPOTIFY_CLIENT_SECRET']
# end

# # Disable session requirement for OmniAuth in API-only mode
# OmniAuth.config.request_validation_phase = lambda { |env| }