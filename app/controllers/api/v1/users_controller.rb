class Api::V1::UsersController < ApplicationController
  before_action :authenticate_user!, except: [:create]
  
  def index
    if params[:query].present?
      # Search users by display name
      users = User.where("display_name ILIKE ?", "%#{params[:query]}%")
        .where.not(id: Current.user.id)
        .limit(20)
    else
      # Return all users except current user
      users = User.where.not(id: Current.user.id).limit(20)
    end
    
    render json: users.map { |user| user_with_compatibility(user) }
  end

  def create
    user = User.create(user_params)
    render json: user
  end
  
  def show
    user = Current.user
    render json: user_with_compatibility(user)
  end

  def user_top_tracks
    user = Current.user
    top_tracks = user.get_top_tracks
    render json: top_tracks
  end

  def user_top_artists
    user = Current.user
    top_artists = user.get_top_artists
    render json: top_artists
  end
  
  def compatibility
    user = Current.user
    compatibility = Current.user.musical_compatibility_with(user, depth: params[:depth]&.to_sym || :medium)
    
    render json: {
      compatibility: compatibility,
      user_id: user.id,
      display_name: user.display_name
    }
  end
  
  def discover_users
    # Find users with similar music taste
    all_users = User.where.not(id: Current.user.id).limit(50)
    
    users_with_compatibility = all_users.map do |user|
      {
        id: user.id,
        display_name: user.display_name,
        profile_photo_url: user.profile_photo_url,
        compatibility: Current.user.musical_compatibility_with(user)
      }
    end
    
    # Sort by compatibility score
    sorted_users = users_with_compatibility.sort_by { |u| -u[:compatibility] }
    
    render json: sorted_users
  end
  
  def music_recommendations
    # Get music recommendations based on friends' listening habits
    recommendations = Current.user.friend_based_recommendations(limit: params[:limit]&.to_i || 20)
    
    # Format the response
    formatted_recommendations = recommendations.map do |track|
      {
        id: track['id'],
        name: track['name'],
        artist: track['artists'].first['name'],
        album: track['album']['name'],
        album_art_url: track['album']['images'].first['url'],
        popularity: track['popularity'],
        preview_url: track['preview_url'],
        uri: track['uri']
      }
    end
    
    render json: formatted_recommendations
  end
  
  private

  def user_params
    params.require(:user).permit(:email, :password)
  end
  
  def user_with_compatibility(user)
    {
      id: user.id,
      display_name: user.display_name,
      profile_photo_url: user.profile_photo_url,
      compatibility: Current.user.musical_compatibility_with(user)
    }
  end
end
