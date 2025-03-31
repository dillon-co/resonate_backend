class Sessions::OmniAuthsController < ApplicationController
    allow_unauthenticated_access only: [ :create, :failure ]
  
    def create
      auth = request.env["omniauth.auth"]
      uid = auth["uid"] || auth["info"]["id"]
      provider = auth["provider"]
      
      # Use the stored redirect_uri from the session if available, otherwise fallback to omniauth.origin or root_path
      redirect_path = session.delete(:omniauth_redirect_uri) || request.env["omniauth.origin"] || root_path
      identity = OmniAuthIdentity.find_by(uid: uid, provider: provider)
      
      if authenticated?
        # User is signed in so they are trying to link an identity with their account
        if identity.nil?
          # No identity was found, create a new one for this user
          OmniAuthIdentity.create(uid: uid, provider: provider, user: Current.user)
          # Give the user model the option to update itself with the new information
          Current.user.signed_in_with_oauth(auth)
          redirect_to "#{redirect_path}?success=true&message=Account+linked"
        else
          # Identity was found, check relation to current user
          if Current.user == identity.user
            # Update the user's OAuth tokens even if already linked
            Current.user.signed_in_with_oauth(auth)
            redirect_to "#{redirect_path}?success=true&message=Already+linked+that+account"
          else
            # The identity is not associated with the current_user, illegal state
            redirect_to "#{redirect_path}?success=false&error=Account+mismatch"
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
        
        # Redirect to the frontend with the token as a URL parameter
        redirect_to "#{redirect_path}?auth_token=#{auth_token}&user_id=#{identity.user.id}&user_name=#{identity.user.display_name}&user_profile_photo_url=#{identity.user.profile_photo_url}"
      end
    end
  
    def failure
      if request.format.json?
        render json: { success: false, error: "Authentication failed" }, status: :unauthorized
      else
        redirect_to new_session_path, alert: "Authentication failed, please try again."
      end
    end

    private

    def generate_auth_token(user)
      payload = { user_id: user.id, exp: 24.hours.from_now.to_i }
      JWT.encode(payload, Rails.application.credentials.secret_key_base)
    end
  end