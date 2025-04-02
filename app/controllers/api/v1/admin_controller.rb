class Api::V1::AdminController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin
  
  def users
    Rails.logger.info("Admin#users called by user #{Current.user.id} with role #{Current.user.role}")
    users = User.all.order(created_at: :desc)
    
    render json: users.map { |user| 
      {
        id: user.id,
        display_name: user.display_name,
        email_address: user.email_address,
        role: user.role,
        profile_photo_url: user.profile_photo_url,
        created_at: user.created_at,
        spotify_connected: user.spotify_access_token.present?
      }
    }
  end
  
  def update_user_role
    Rails.logger.info("Admin#update_user_role called by user #{Current.user.id} with role #{Current.user.role}")
    user = User.find(params[:id])
    
    if user.update(role: params[:role])
      render json: { success: true, message: "User role updated successfully" }
    else
      render json: { success: false, error: user.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end
  
  private
  
  def require_admin
    Rails.logger.info("Checking admin role for user #{Current.user.id}: role=#{Current.user.role}, admin?=#{Current.user.admin?}")
    
    unless Current.user&.admin?
      Rails.logger.warn("Unauthorized admin access attempt by user #{Current.user.id} with role #{Current.user.role}")
      render json: { error: "Unauthorized. Admin access required." }, status: :unauthorized
    end
  end
end
