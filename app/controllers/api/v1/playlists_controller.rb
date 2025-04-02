class Api::V1::PlaylistsController < ApplicationController
  before_action :authenticate_user!
  
  # POST /api/v1/playlists/shared/:user_id
  # Create a shared playlist with another user
  def create_shared
    other_user = User.find(params[:user_id])
    
    # Check if users are friends
    unless Current.user.is_friend_with?(other_user)
      return render json: { error: "You must be friends with this user to create a shared playlist" }, status: :forbidden
    end
    
    # Check if both users have Spotify connected
    unless Current.user.spotify_connected? && other_user.spotify_connected?
      return render json: { error: "Both users must have Spotify connected to create a shared playlist" }, status: :unprocessable_entity
    end
    
    # Create the shared playlist
    playlist = Current.user.create_shared_playlist_with(other_user)
    
    if playlist
      render json: { playlist: playlist }, status: :created
    else
      render json: { error: "Failed to create shared playlist" }, status: :unprocessable_entity
    end
  end
  
  private
  
  def playlist_params
    params.require(:playlist).permit(:name, :description)
  end
end
