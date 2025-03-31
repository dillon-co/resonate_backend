class Sessions::OmniAuthsController < ApplicationController
    allow_unauthenticated_access only: [ :create, :failure ]
  
    def create
      auth = request.env["omniauth.auth"]
      uid = auth["uid"] || auth["info"]["id"]
      provider = auth["provider"]
      
      # Get the redirect_uri from the session or request params
      # If running locally, redirect to localhost:5173, otherwise use the origin
      redirect_uri = session.delete(:omniauth_redirect_uri)
      
      # If no explicit redirect_uri was provided, check the origin or use a default
      if redirect_uri.blank?
        origin = request.env["omniauth.origin"]
        redirect_uri = if Rails.env.development? || origin&.include?('localhost')
                        "http://localhost:5173"
                      else
                        origin || "https://dillon-co.github.io"
                      end
      end
      
      identity = OmniAuthIdentity.find_by(uid: uid, provider: provider)
      
      if authenticated?
        # User is signed in so they are trying to link an identity with their account
        if identity.nil?
          # No identity was found, create a new one for this user
          OmniAuthIdentity.create(uid: uid, provider: provider, user: Current.user)
          # Give the user model the option to update itself with the new information
          Current.user.signed_in_with_oauth(auth)
          
          # Return response based on format
          respond_to_oauth_result(
            success: true,
            message: "Account linked",
            redirect_uri: redirect_uri
          )
        else
          # Identity was found, check relation to current user
          if Current.user == identity.user
            # Update the user's OAuth tokens even if already linked
            Current.user.signed_in_with_oauth(auth)
            
            # Return response based on format
            respond_to_oauth_result(
              success: true,
              message: "Account already linked",
              redirect_uri: redirect_uri
            )
          else
            # The identity is not associated with the current_user, illegal state
            respond_to_oauth_result(
              success: false,
              error: "Account mismatch",
              redirect_uri: redirect_uri
            )
          end
        end
      else
        # Check if identity was found i.e. user has visited the site before
        if identity.nil?
          # New identity visiting the site, we are linking to an existing User or creating a new one
          user = User.find_by(email_address: auth.info.email)
          
          if user
            # User exists but needs to be updated with Spotify tokens
            user.signed_in_with_oauth(auth)
          else
            # Create new user with Spotify tokens
            user = User.create_from_oauth(auth)
          end
          
          identity = OmniAuthIdentity.create(uid: uid, provider: provider, user: user)
        else
          # User exists, update their Spotify tokens
          identity.user.signed_in_with_oauth(auth)
        end
        
        start_new_session_for identity.user
        
        # Generate a token you can pass to the frontend
        auth_token = generate_auth_token(identity.user)
        
        # Return response with auth data
        respond_to_oauth_result(
          success: true,
          auth_token: auth_token,
          user_id: identity.user.id,
          user_name: identity.user.display_name,
          user_profile_photo_url: identity.user.profile_photo_url,
          redirect_uri: redirect_uri
        )
      end
    end
  
    def failure
      # Determine the appropriate redirect URI based on the environment
      redirect_uri = if Rails.env.development?
                      "http://localhost:5173"
                    else
                      "https://dillon-co.github.io"
                    end
      
      # Return failure response
      respond_to_oauth_result(
        success: false,
        error: "Authentication failed",
        redirect_uri: redirect_uri
      )
    end

    private

    def generate_auth_token(user)
      payload = { user_id: user.id, exp: 24.hours.from_now.to_i }
      JWT.encode(payload, Rails.application.secret_key_base)
    end
    
    def respond_to_oauth_result(data)
      # Format the data as JSON
      json_data = data.to_json
      
      # Create a safe JavaScript representation of the data
      js_data = json_data.html_safe
      
      # Return HTML with embedded JavaScript that handles both redirect and API scenarios
      html = <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
          <title>Authentication Complete</title>
          <script>
            // The authentication data
            var authData = #{js_data};
            
            // Function to handle different client types
            function handleAuthResult() {
              // Check if this is a mobile app webview that can receive messages
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.authCallback) {
                // iOS WebView
                window.webkit.messageHandlers.authCallback.postMessage(authData);
                return;
              }
              
              if (window.authCallback) {
                // Android WebView
                window.authCallback.receiveAuthData(JSON.stringify(authData));
                return;
              }
              
              // Check if we're in a popup window opened by the parent
              if (window.opener && !window.opener.closed) {
                // We're in a popup, send message to parent and close
                window.opener.postMessage(authData, "*");
                window.close();
                return;
              }
              
              // Regular browser flow - redirect with hash params
              var redirectUri = authData.redirect_uri || "/";
              
              // Build the hash fragment
              var hashParams = [];
              Object.keys(authData).forEach(function(key) {
                if (key !== 'redirect_uri') {
                  hashParams.push(key + '=' + encodeURIComponent(authData[key]));
                }
              });
              
              // Redirect with hash params
              window.location.href = redirectUri + '#' + hashParams.join('&');
            }
            
            // Execute the handler
            handleAuthResult();
          </script>
        </head>
        <body>
          <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; 
                      max-width: 500px; margin: 0 auto; padding: 20px; text-align: center;">
            <h2 style="color: #333; margin-bottom: 20px;">Authentication Complete</h2>
            <p style="color: #666; line-height: 1.5;">
              #{data[:success] ? 'Authentication successful!' : 'Authentication failed: ' + (data[:error] || 'Unknown error')}
            </p>
            <p style="color: #666; margin-top: 20px;">
              You can close this window now. Redirecting you back to the application...
            </p>
          </div>
        </body>
        </html>
      HTML
      
      render html: html.html_safe
    end
  end