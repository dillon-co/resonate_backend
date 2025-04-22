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
    # Eager load anthem track
    current_user_with_anthem = User.includes(:anthem_track).find(Current.user.id)
    
    render json: user_with_compatibility_and_anthem(current_user_with_anthem)
  end

  def current_with_role
    user = Current.user
    Rails.logger.info("UsersController#current_with_role called for user #{user.id} with role #{user.role}")
    
    # Return a consistent response format
    render json: {
      id: user.id,
      display_name: user.display_name,
      role: user.role,
      email_address: user.email_address,
      profile_photo_url: user.profile_photo_url
    }
  rescue => e
    Rails.logger.error("Error in current_with_role: #{e.message}")
    render json: { error: "Error retrieving user role" }, status: :internal_server_error
  end

  def show_profile
    user = User.find_by(id: params[:id])
    
    if user
      # Eager load anthem track
      user_with_anthem = User.includes(:anthem_track).find(params[:id])
      
      # Include compatibility data if viewing another user's profile
      profile_data = if user.id != Current.user.id
                       user_with_compatibility_and_anthem(user_with_anthem)
                     else
                       # If viewing own profile, no need to calculate compatibility
                       {
                         id: user.id,
                         display_name: user.display_name,
                         profile_photo_url: user.profile_photo_url,
                         anthem_track: format_track(user.anthem_track)
                       }
                     end
      
      # Add Spotify data if the user has connected their account
      if user.spotify_access_token.present?
        # Get top tracks and artists
        begin
          # The get_top_tracks and get_top_artists methods now return formatted arrays
          # not the raw Spotify API response
          top_tracks = user.get_top_tracks(limit: 10)
          top_artists = user.get_top_artists(limit: 10)
          
          # Ensure we have arrays even if the methods return nil
          top_tracks = [] unless top_tracks.is_a?(Array)
          top_artists = [] unless top_artists.is_a?(Array)
          
          # Log for debugging
          Rails.logger.info("User #{user.id} top tracks: #{top_tracks.size} items")
          Rails.logger.info("User #{user.id} top artists: #{top_artists.size} items")
          
          profile_data[:spotify_connected] = true
          profile_data[:top_tracks] = top_tracks
          profile_data[:top_artists] = top_artists
        rescue => e
          Rails.logger.error("Error fetching Spotify data for user #{user.id}: #{e.message}")
          profile_data[:spotify_connected] = true
          profile_data[:top_tracks] = []
          profile_data[:top_artists] = []
          profile_data[:spotify_error] = "Could not fetch music data"
        end
      else
        profile_data[:spotify_connected] = false
      end
      
      render json: profile_data
    else
      render json: { error: "User not found" }, status: :not_found
    end
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
    recommendations_hash = Current.user.friend_based_recommendations(limit: params[:limit]&.to_i || 20)
    
    # Access the 'tracks' array from the hash
    recommendation_tracks = recommendations_hash['tracks'] || []
    
    # Format the response
    formatted_recommendations = recommendation_tracks.map do |track|
      # Handle different track formats
      if track.is_a?(Hash) && track[:id].present?
        # Handle format from our fallback mechanism (symbol keys)
        {
          id: track[:id],
          name: track[:name],
          artist: track[:artist],
          album: track[:album] || "Unknown Album",
          album_art_url: track[:album_art_url] || track[:image_url] || "https://via.placeholder.com/300",
          popularity: track[:popularity] || 0,
          preview_url: track[:preview_url],
          uri: track[:uri] || "spotify:track:#{track[:id]}"
        }
      elsif track.is_a?(Hash) && track['id'].present?
        # Handle format from Spotify API (string keys)
        artist_name = if track['artists'] && track['artists'].first
                        track['artists'].first['name']
                      else
                        "Unknown Artist"
                      end
                      
        album_name = track['album'] ? track['album']['name'] : "Unknown Album"
        
        album_art = if track['album'] && track['album']['images'] && track['album']['images'].first
                      track['album']['images'].first['url']
                    else
                      "https://via.placeholder.com/300"
                    end
        
        {
          id: track['id'],
          name: track['name'],
          artist: artist_name,
          album: album_name,
          album_art_url: album_art,
          popularity: track['popularity'] || 0,
          preview_url: track['preview_url'],
          uri: track['uri'] || "spotify:track:#{track['id']}"
        }
      else
        # Skip invalid tracks
        nil
      end
    end.compact # Remove any nil entries
    
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
  
  def user_with_compatibility_and_anthem(user)
    {
      id: user.id,
      display_name: user.display_name,
      profile_photo_url: user.profile_photo_url,
      compatibility: Current.user.musical_compatibility_with(user),
      anthem_track: format_track(user.anthem_track)
    }
  end
  
  def format_track(track)
    return nil unless track
    {
      id: track.id,
      name: track.song_name,
      artist: track.artist,
      album_art_url: track.image_url,
      spotify_id: track.spotify_id,
      preview_url: track.preview_url
      # Add other relevant track details if needed
    }
  end
end
