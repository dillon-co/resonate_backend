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
  
  # GET /api/v1/users/:id
  # Returns detailed profile data for a specific user
  def show
    # Find the user whose profile is being requested
    target_user = User.includes(:anthem_track).find_by(id: params[:id])

    if target_user
      # Pass the target user and the current user (requester) to the helper
      profile_data = user_profile_data(target_user, Current.user)
      render json: profile_data
    else
      render json: { error: "User not found" }, status: :not_found
    end
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
        profile_data[:spotify_connected] = true
        begin
          # Fetch top tracks, artists, and genres using cache
          profile_data[:top_tracks] = Rails.cache.fetch("user:#{user.id}:top_tracks:short_term", expires_in: 1.hour) do
            user.get_top_tracks(limit: 10) # Keep existing limit for now
          end
          profile_data[:top_artists] = Rails.cache.fetch("user:#{user.id}:top_artists:short_term", expires_in: 1.hour) do
            user.get_top_artists(limit: 10) # Keep existing limit for now
          end
          
          # Fetch favorite genres
          genre_data = Rails.cache.fetch("user:#{user.id}:genre_breakdown", expires_in: 1.hour) do
            user.genre_breakdown
          end
          profile_data[:favorite_genres] = genre_data.keys.take(5) # Get top 5 genre names
          
          # Ensure we have arrays even if the methods return nil or cache misses occur
          profile_data[:top_tracks] ||= []
          profile_data[:top_artists] ||= []
          profile_data[:favorite_genres] ||= [] # Ensure it's an array on error/miss
          
          # Log for debugging
          Rails.logger.info("User #{user.id} show_profile - Tracks: #{profile_data[:top_tracks].size}, Artists: #{profile_data[:top_artists].size}, Genres: #{profile_data[:favorite_genres].size}")
          
        rescue => e
          Rails.logger.error("Error fetching Spotify data for user #{user.id} in show_profile: #{e.message}")
          # Reset on error
          profile_data[:top_tracks] = []
          profile_data[:top_artists] = []
          profile_data[:favorite_genres] = []
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
  
  def user_profile_data(user, requester = nil)
    data = {
      id: user.id,
      display_name: user.display_name,
      profile_photo_url: user.profile_photo_url,
      spotify_connected: user.spotify_access_token.present?,
      anthem_track: format_track(user.anthem_track) # Add formatted anthem track
    }

    # Only include sensitive or extended data if requester is the user themselves or a friend
    can_view_details = requester.nil? || requester == user || requester.is_friend_with?(user)

    if can_view_details && user.spotify_access_token.present?
      begin
        # Fetch data only if allowed and connected
        # Use cached data if available, otherwise fetch fresh
        # Note: Consider moving API calls to background jobs or services for better performance
        data[:top_artists] = Rails.cache.fetch("user:#{user.id}:top_artists:short_term", expires_in: 1.hour) do
          user.get_top_artists(limit: 9)
        end
        data[:top_tracks] = Rails.cache.fetch("user:#{user.id}:top_tracks:short_term", expires_in: 1.hour) do
          user.get_top_tracks(limit: 5)
        end
        
        # Add favorite genres (top 5)
        genre_data = Rails.cache.fetch("user:#{user.id}:genre_breakdown", expires_in: 1.hour) do
          user.genre_breakdown
        end
        data[:favorite_genres] = genre_data.keys.take(5) # Get top 5 genre names
        
        # Add compatibility score if viewing another user's profile
        if requester && requester != user
          data[:compatibility] = requester.musical_compatibility_with(user)
        end
        
      rescue => e
        Rails.logger.error "Error fetching Spotify data for user #{user.id} in profile: #{e.message}"
        # Return basic data even if Spotify fetch fails
        data[:top_artists] = [] # Default to empty array on error
        data[:top_tracks] = []  # Default to empty array on error
        data[:favorite_genres] = [] # Default to empty array on error
      end
    else
      # Set defaults if user cannot view details or not connected
      data[:top_artists] = []
      data[:top_tracks] = []
      data[:favorite_genres] = []
    end

    data
  end
end
