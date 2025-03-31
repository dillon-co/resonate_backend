module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    # This method is used by controllers to authenticate users
    def authenticate_user!
      unless authenticated?
        request_authentication
      end
    end

    def resume_session
      # binding.pry
      Current.session ||= find_session_by_token
    end

    def find_session_by_token
      # First try to find token in params
      token = request.params[:code]
      
      # If not in params, try to extract from Authorization header
      if token.blank? && request.headers['Authorization'].present?
        auth_header = request.headers['Authorization']
        # Extract the token from "Bearer <token>"
        token = auth_header.split(' ').last if auth_header.start_with?('Bearer ')
      end
      
      # If we have a token, try to decode it as JWT
      if token.present?
        begin
          # Decode the JWT token
          decoded_token = JWT.decode(token, Rails.application.credentials.secret_key_base, true, { algorithm: 'HS256' })
          user_id = decoded_token.first['user_id']
          
          # Find the user and create a session for them
          user = User.find_by(id: user_id)
          return user.sessions.first if user && user.sessions.any?
        rescue JWT::DecodeError => e
          Rails.logger.error("JWT decode error: #{e.message}")
          # If JWT decode fails, try to find a session by token (legacy method)
          return Session.find_by(token: token)
        end
      end
      
      nil
    end

    def request_authentication
      render json: { error: "Authentication required" }, status: :unauthorized
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || "/"
    end

    def start_new_session_for(user)
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
      end
    end

    def terminate_session
      Current.session.destroy
    end
end
