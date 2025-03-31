class Sessions::OmniAuthsController < ApplicationController
    allow_unauthenticated_access only: [ :create, :failure ]
  
    def create
      auth = request.env["omniauth.auth"]
      uid = auth["uid"] || auth["info"]["id"]
      provider = auth["provider"]
      
      # Get the redirect_uri from the session or request
      redirect_path = session.delete(:omniauth_redirect_uri) || request.env["omniauth.origin"] || "/"
      identity = OmniAuthIdentity.find_by(uid: uid, provider: provider)
      
      if authenticated?
        # User is signed in so they are trying to link an identity with their account
        if identity.nil?
          # No identity was found, create a new one for this user
          OmniAuthIdentity.create(uid: uid, provider: provider, user: Current.user)
          # Give the user model the option to update itself with the new information
          Current.user.signed_in_with_oauth(auth)
          
          # Return success HTML with script to close popup and notify parent window
          render html: <<~HTML.html_safe
            <!DOCTYPE html>
            <html>
            <head>
              <title>Account Linked</title>
              <script>
                window.opener.postMessage({ success: true, message: "Account linked" }, "*");
                window.close();
              </script>
            </head>
            <body>
              <p>Account linked successfully. You can close this window.</p>
            </body>
            </html>
          HTML
        else
          # Identity was found, check relation to current user
          if Current.user == identity.user
            # Update the user's OAuth tokens even if already linked
            Current.user.signed_in_with_oauth(auth)
            
            # Return success HTML with script to close popup and notify parent window
            render html: <<~HTML.html_safe
              <!DOCTYPE html>
              <html>
              <head>
                <title>Account Already Linked</title>
                <script>
                  window.opener.postMessage({ success: true, message: "Account already linked" }, "*");
                  window.close();
                </script>
              </head>
              <body>
                <p>Account already linked. You can close this window.</p>
              </body>
              </html>
            HTML
          else
            # The identity is not associated with the current_user, illegal state
            render html: <<~HTML.html_safe
              <!DOCTYPE html>
              <html>
              <head>
                <title>Account Mismatch</title>
                <script>
                  window.opener.postMessage({ success: false, error: "Account mismatch" }, "*");
                  window.close();
                </script>
              </head>
              <body>
                <p>Account mismatch error. You can close this window.</p>
              </body>
              </html>
            HTML
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
        
        # Return HTML with JavaScript that will pass the token to the parent window and close
        render html: <<~HTML.html_safe
          <!DOCTYPE html>
          <html>
          <head>
            <title>Authentication Successful</title>
            <script>
              window.opener.postMessage({
                success: true,
                auth_token: "#{auth_token}",
                user_id: "#{identity.user.id}",
                user_name: "#{identity.user.display_name}",
                user_profile_photo_url: "#{identity.user.profile_photo_url}"
              }, "*");
              window.close();
            </script>
          </head>
          <body>
            <p>Authentication successful! You can close this window.</p>
          </body>
          </html>
        HTML
      end
    end
  
    def failure
      # Return HTML with JavaScript that will notify the parent window of failure and close
      render html: <<~HTML.html_safe
        <!DOCTYPE html>
        <html>
        <head>
          <title>Authentication Failed</title>
          <script>
            window.opener.postMessage({ success: false, error: "Authentication failed" }, "*");
            window.close();
          </script>
        </head>
        <body>
          <p>Authentication failed. You can close this window.</p>
        </body>
        </html>
      HTML
    end

    private

    def generate_auth_token(user)
      payload = { user_id: user.id, exp: 24.hours.from_now.to_i }
      JWT.encode(payload, Rails.application.credentials.secret_key_base)
    end
  end