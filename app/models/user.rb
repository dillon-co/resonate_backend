class User < ApplicationRecord
  vectorsearch
  has_secure_password
  has_many :sessions, dependent: :destroy
  normalizes :email_address, with: ->(e) { e.strip.downcase }
  
  # Friendship associations
  has_many :friendships
  has_many :friends, -> { where(friendships: { status: :accepted }) }, through: :friendships
  has_many :received_friendships, class_name: 'Friendship', foreign_key: 'friend_id'
  has_many :received_friends, through: :received_friendships, source: :user

  has_many :user_tracks
  has_many :tracks, through: :user_tracks, source: :track
  has_many :user_artists
  has_many :artists, through: :user_artists, source: :artist
  has_many :user_albums
  has_many :albums, through: :user_albums, source: :album

  belongs_to :anthem_track, class_name: 'Track', optional: true

  enum :role, [ :user, :admin ]
  # OAuth methods
  def self.create_from_oauth(auth)
    email = auth.info['email']
    
    user = self.new(
      email_address: email, 
      password: SecureRandom.base64(64).truncate_bytes(64), 
      display_name: auth.info['display_name'] || auth.info['name'], 
      profile_photo_url: auth.info['images']&.first&.fetch('url', nil),
      spotify_id: auth.uid || auth.info['id'],
      spotify_access_token: auth.credentials.token,
      spotify_refresh_token: auth.credentials.refresh_token,
      spotify_token_expires_at: Time.at(auth.credentials.expires_at)
    )
    user.save
    user
  end
  
  def signed_in_with_oauth(auth)
    update(
      spotify_access_token: auth.credentials.token,
      spotify_refresh_token: auth.credentials.refresh_token,
      spotify_token_expires_at: Time.at(auth.credentials.expires_at),
      display_name: auth.info['display_name'] || auth.info['name'],
      profile_photo_url: auth.info['images']&.first&.fetch('url', nil)
    )
  end

  def update_embedding
  
  end  
  
  #-----------------------
  # Spotify API Methods
  #-----------------------
  
  def get_top_tracks(time_range: 'short_term', limit: 50)
    # time_range options: short_term (4 weeks), medium_term (6 months), long_term (years)
    response = spotify_api_call("me/top/tracks", params: { time_range: time_range, limit: limit })
    formatted_response = format_tracks_response(response)
    
    # Log the response for debugging
    Rails.logger.info("Top tracks response for user #{id}: #{formatted_response.inspect}")
    
    # Find or create tracks and user_tracks
    formatted_response.each do |track_data|
      # Find or create the track based on Spotify ID
      track = Track.find_or_create_by(spotify_id: track_data[:id]) do |new_track|
        new_track.song_name = track_data[:name]
        new_track.artist = track_data[:artist]
        new_track.image_url = track_data[:album_art_url]
        new_track.preview_url = track_data[:preview_url]
      end
      
      # Find or create the user_track association
      UserTrack.find_or_create_by(user_id: id, track_id: track.id)
      
      # Enqueue background job to process track data
      TrackDataJob.perform_async(track.id)
    end
    
    formatted_response
  end
  
  def get_top_artists(time_range: 'short_term', limit: 50)
    response = spotify_api_call("me/top/artists", params: { time_range: time_range, limit: limit })
    formatted_response = format_artists_response(response)
    
    # Log the response for debugging
    Rails.logger.info("Top artists response for user #{id}: #{formatted_response.inspect}")
    
    # Find or create artists and user_artists
    formatted_response.each do |artist_data|
      # Find or create the artist based on Spotify ID
      artist = Artist.find_or_create_by(spotify_id: artist_data[:id]) do |new_artist|
        new_artist.name = artist_data[:name]
        new_artist.image_url = artist_data[:image_url]
        new_artist.genre = artist_data[:genres].first if artist_data[:genres].present?
      end
      
      # Find or create the user_artist association
      UserArtist.find_or_create_by(user_id: id, artist_id: artist.id)
      
      # Enqueue background job to process artist data
      ArtistDataJob.perform_async(artist.id)
    end
    
    formatted_response
  end
  
  def get_recently_played(limit: 50)
    spotify_api_call("me/player/recently-played", params: { limit: limit })
  end
  
  def get_saved_tracks(limit: 50, offset: 0)
    spotify_api_call("me/tracks", params: { limit: limit, offset: offset })
  end
  
  def get_playlists(limit: 50, offset: 0)
    spotify_api_call("me/playlists", params: { limit: limit, offset: offset })
  end
  
  def get_recommendations(seed_artists: nil, seed_tracks: nil, seed_genres: nil, limit: 20)
    # If no seeds are provided, use embedding-based recommendations
    if (seed_artists.nil? || seed_artists.empty?) && 
       (seed_tracks.nil? || seed_tracks.empty?) && 
       (seed_genres.nil? || seed_genres.empty?)
      Rails.logger.info("No seeds provided, using embedding-based recommendations")
      return MusicRecommendationService.get_embedding_recommendations_for_user(self, limit: limit)
    end
    
    # Validate seed tracks - ensure they're valid Spotify IDs
    if seed_tracks && !seed_tracks.empty?
      # If we received an array of track objects from get_top_tracks
      if seed_tracks.first.is_a?(Hash)
        Rails.logger.info("Converting track objects to IDs")
        seed_tracks = seed_tracks.map { |track| track[:id] || track['id'] }.compact
      end
      
      Rails.logger.info("Using seed tracks for recommendations: #{seed_tracks.join(', ')}")
      # Filter out any obviously invalid IDs
      seed_tracks = seed_tracks.select { |id| id.is_a?(String) && !id.empty? }
      
      # Ensure we don't exceed Spotify's limit of 5 seed values total
      seed_tracks = seed_tracks.take(5)
    end
    
    # Build parameters - Spotify expects comma-separated strings for seed values
    params = { limit: limit }
    
    # Add seed parameters if present
    if seed_artists && !seed_artists.empty?
      seed_artists = seed_artists.take(5) # Spotify limit
      params[:seed_artists] = seed_artists.join(',')
    end
    
    if seed_tracks && !seed_tracks.empty?
      params[:seed_tracks] = seed_tracks.join(',')
    end
    
    if seed_genres && !seed_genres.empty?
      seed_genres = seed_genres.take(5) # Spotify limit
      params[:seed_genres] = seed_genres.join(',')
    end
    
    # For debugging
    Rails.logger.info("Spotify recommendations params: #{params.inspect}")
    
    # Try to get from cache first
    cache_key = "spotify:recommendations:#{params.to_s}"
    cached_recommendations = Rails.cache.read(cache_key)
    return cached_recommendations if cached_recommendations.present?
    
    # Make the API call - try both endpoint formats
    begin
      # Try the browse/recommendations endpoint first (this is the correct one according to latest Spotify docs)
      response = spotify_api_call("browse/recommendations", params: params)
      
      # If that fails with a 404, try the regular recommendations endpoint
      if response.blank? || !response['tracks']
        Rails.logger.warn("First attempt failed, trying alternative endpoint")
        response = spotify_api_call("recommendations", params: params)
      end
      
      # For debugging
      if response.blank? || !response['tracks']
        Rails.logger.error("Empty or invalid response from Spotify recommendations API: #{response.inspect}")
        
        # Try a fallback with just one seed track as a last resort
        if seed_tracks && seed_tracks.length > 1
          Rails.logger.info("Trying with just one seed track as fallback")
          single_seed_params = { limit: limit, seed_tracks: seed_tracks.first }
          response = spotify_api_call("browse/recommendations", params: single_seed_params)
        end
        
        # If Spotify API still fails, fall back to embedding-based recommendations
        if response.blank? || !response['tracks'] || response['tracks'].empty?
          Rails.logger.info("Spotify API failed, falling back to embedding-based recommendations")
          return MusicRecommendationService.get_embedding_recommendations_for_user(self, limit: limit)
        end
      else
        Rails.logger.info("Successfully got recommendations with #{response['tracks'].size} tracks")
      end
      
      # Cache successful responses
      Rails.cache.write(cache_key, response, expires_in: 1.day) if response.present? && response['tracks']
      
      response
    rescue => e
      Rails.logger.error("Error getting recommendations: #{e.message}")
      # Fall back to embedding-based recommendations on error
      Rails.logger.info("Spotify API error, falling back to embedding-based recommendations")
      MusicRecommendationService.get_embedding_recommendations_for_user(self, limit: limit)
    end
  end
  
  def get_audio_features(track_ids)
    # track_ids should be an array of Spotify track IDs
    return [] if track_ids.empty?
    
    # Spotify API allows up to 100 track IDs per request
    track_ids.each_slice(100).flat_map do |batch|
      response = spotify_api_call("audio-features", params: { ids: batch.join(',') })
      response && response['audio_features'] ? response['audio_features'] : []
    end
  end
  
  # Get full Spotify user profile
  def get_spotify_profile
    spotify_api_call("me")
  end
  
  # Get a specific track
  def get_track(track_id)
    spotify_api_call("tracks/#{track_id}")
  end
  
  # Get several tracks at once
  def get_tracks(track_ids)
    return [] if track_ids.empty?
    
    # Spotify API allows up to 50 track IDs per request
    track_ids.each_slice(50).flat_map do |batch|
      response = spotify_api_call("tracks", params: { ids: batch.join(',') })
      response && response['tracks'] ? response['tracks'] : []
    end
  end
  
  # Get all user's liked songs (paginated requests)
  def get_all_saved_tracks
    tracks = []
    offset = 0
    limit = 50
    
    loop do
      response = get_saved_tracks(limit: limit, offset: offset)
      break unless response && response['items']
      
      tracks.concat(response['items'])
      break if response['items'].size < limit
      
      offset += limit
    end
    
    tracks
  end
  
  # Get user's saved albums from Spotify
  def get_saved_albums(limit: 50, offset: 0)
    response = spotify_api_call("me/albums", params: { limit: limit, offset: offset })
    
    return [] unless response && response['items'].is_a?(Array)
    
    formatted_albums = response['items'].map do |item|
      album = item['album']
      {
        id: album['id'],
        name: album['name'],
        artist: album['artists'].first['name'],
        image_url: album['images'].first&.dig('url'),
        release_date: album['release_date'],
        total_tracks: album['total_tracks'],
        uri: album['uri']
      }
    end
    
    # Log the response for debugging
    Rails.logger.info("Saved albums response for user #{id}: #{formatted_albums.inspect}")
    
    # Find or create albums and user_album associations
    formatted_albums.each do |album_data|
      # Find or create the album based on Spotify ID
      album = Album.find_or_create_by(spotify_id: album_data[:id]) do |new_album|
        new_album.title = album_data[:name]
        new_album.artist = album_data[:artist]
        new_album.genre = nil # Will be populated by AlbumDataJob
        new_album.mood = nil # Will be populated by AlbumDataJob
        new_album.energy_level = nil # Will be populated by AlbumDataJob
        new_album.themes = nil # Will be populated by AlbumDataJob
      end
      
      # Due to the typo in the model name (UserAbum instead of UserAlbum)
      # and the incorrect association (with artist instead of album),
      # we need to find a workaround.
      # For now, we'll create a UserAlbum record but associate it with the album's ID
      # This should be fixed in a future migration
      
      # Find or create the user_album association
      UserAlbum.find_or_create_by(user_id: id, artist_id: album.id)
      
      # Enqueue background job to process album data
      AlbumDataJob.perform_async(album.id)
    end
    
    formatted_albums
  end
  
  #-----------------------
  # Music Discovery Methods
  #-----------------------
  
  # Get tracks that your friends listen to that you don't
  def discover_new_tracks_from_friends(limit: 30)
    # Collect top tracks from all friends
    friend_tracks = friends.flat_map do |friend| 
      begin
        friend_top = friend.get_top_tracks
        friend_top && friend_top['items'] ? friend_top['items'] : []
      rescue => e
        Rails.logger.error("Error fetching friend tracks: #{e.message}")
        []
      end
    end
    
    # Get your top track IDs to filter them out
    my_top = get_top_tracks
    my_top_track_ids = my_top && my_top['items'] ? my_top['items'].map { |t| t['id'] } : []
    
    my_saved = get_saved_tracks
    my_saved_track_ids = my_saved && my_saved['items'] ? my_saved['items'].map { |t| t['track']['id'] } : []
    
    my_track_ids = (my_top_track_ids + my_saved_track_ids).uniq
    
    # Filter out tracks you already know
    new_tracks = friend_tracks.reject { |track| my_track_ids.include?(track['id']) }
    
    # Count occurrence of each track among friends (popularity among your circle)
    track_counts = Hash.new(0)
    new_tracks.each { |track| track_counts[track['id']] += 1 }
    
    # Sort by popularity among friends and take top ones
    popular_track_ids = track_counts.sort_by { |_, count| -count }.take(limit).map(&:first)
    
    # Return the actual track objects for the top tracks
    popular_track_ids.map { |id| new_tracks.find { |t| t['id'] == id } }.compact
  end
  
  # Find musical compatibility score with another user
  # def musical_compatibility_with(other_user, depth: :medium)
  #   time_range = time_range_for_depth(depth)
    
  #   # Get cached data or fetch if not available
  #   my_artists = Rails.cache.fetch("user:#{id}:top_artists:#{time_range}", expires_in: 1.day) do
  #     get_top_artists(time_range: time_range)
  #   end
    
  #   their_artists = Rails.cache.fetch("user:#{other_user.id}:top_artists:#{time_range}", expires_in: 1.day) do
  #     other_user.get_top_artists(time_range: time_range)
  #   end
    
  #   # Ensure we have arrays
  #   my_artists = my_artists.is_a?(Array) ? my_artists : []
  #   their_artists = their_artists.is_a?(Array) ? their_artists : []
    
  #   # Extract IDs - the formatted response has id as a key, not 'id'
  #   my_artist_ids = my_artists.map { |a| a[:id] }
  #   their_artist_ids = their_artists.map { |a| a[:id] }
    
  #   # Calculate overlap
  #   common_artists = my_artist_ids & their_artist_ids
  #   total_artists = my_artist_ids | their_artist_ids
    
  #   # Simple Jaccard similarity coefficient
  #   artist_similarity = total_artists.empty? ? 0 : (common_artists.size.to_f / total_artists.size)
    
  #   # Get audio features for both users' top tracks to compare musical preferences
  #   my_tracks = Rails.cache.fetch("user:#{id}:top_tracks:#{time_range}", expires_in: 1.day) do
  #     get_top_tracks(time_range: time_range)
  #   end
    
  #   their_tracks = Rails.cache.fetch("user:#{other_user.id}:top_tracks:#{time_range}", expires_in: 1.day) do
  #     other_user.get_top_tracks(time_range: time_range)
  #   end
    
  #   # Ensure we have arrays
  #   my_tracks = my_tracks.is_a?(Array) ? my_tracks : []
  #   their_tracks = their_tracks.is_a?(Array) ? their_tracks : []
    
  #   # Compare audio features if there are tracks
  #   feature_similarity = 0
  #   # if !my_tracks.empty? && !their_tracks.empty?
  #   #   my_track_ids = my_tracks.map { |t| t[:id] }
  #   #   their_track_ids = their_tracks.map { |t| t[:id] }
      
  #   #   my_features = get_audio_features(my_track_ids)
  #   #   their_features = other_user.get_audio_features(their_track_ids)
      
  #   #   # Calculate distance between feature vectors (normalized)
  #   #   feature_similarity = calculate_feature_similarity(my_features, their_features)
  #   # end
    
  #   # Combine metrics (you can adjust weights) - keep as decimal (0-1)
  #   overall_score = (artist_similarity * 0.6) #+ (feature_similarity * 0.4)
    
  #   # Ensure the score is between 0 and 1 before converting to percentage
  #   overall_score = [0, [overall_score, 1].min].max
    
  #   # Return score as percentage (ensure it's not greater than 100)
  #   [overall_score * 100, 100].min.round(1)
  # end
  
  def musical_compatibility_with(other_user, depth: :medium)
    MusicCompatibilityService.calculate_compatibility(self, other_user, depth: depth)
  end
  
  # Generate recommendations based on friends' listening habits
  def friend_based_recommendations(limit: 20)
    # Try to get from cache first
    cache_key = "user:#{id}:friend_recommendations:#{limit}"
    cached_recommendations = Rails.cache.read(cache_key)
    return cached_recommendations if cached_recommendations.present?

    # If we have no friends, use our own embedding-based recommendations
    if friends.empty?
      Rails.logger.info("No friends found, using own embedding-based recommendations")
      result = MusicRecommendationService.get_embedding_recommendations_for_user(self, limit: limit)
      # Cache the result
      Rails.cache.write(cache_key, result, expires_in: 1.day) if result.present?
      return result
    end

    # Try to get recommendations based on combined friend embeddings
    begin
      # Collect embeddings from friends who have them
      friend_embeddings = friends.map(&:embedding).compact
      
      # If none of the friends have embeddings, fall back to traditional method
      if friend_embeddings.empty?
        Rails.logger.info("No friend embeddings found, falling back to traditional method")
        return traditional_friend_recommendations(limit)
      end
      
      # Add our own embedding if available
      if self.embedding.present?
        friend_embeddings << self.embedding
      else
        # Try to generate our embedding
        UserEmbeddingService.update_embedding_for(self)
        friend_embeddings << self.embedding if self.embedding.present?
      end
      
      # Calculate average embedding from all friends (and possibly self)
      avg_embedding = UserEmbeddingService.send(:calculate_average_embedding, friend_embeddings)
      
      if avg_embedding.nil?
        Rails.logger.info("Could not calculate average embedding, falling back to traditional method")
        return traditional_friend_recommendations(limit)
      end
      
      # Create a temporary user object with the average embedding to use with the recommendation service
      temp_user = User.new
      temp_user.embedding = avg_embedding
      
      # Get recommendations using the combined embedding
      result = MusicRecommendationService.get_track_recommendations_by_embedding(temp_user, limit)
      
      # If we didn't get enough recommendations, fall back to traditional method
      if result.empty? || result.size < limit / 2
        Rails.logger.info("Not enough embedding-based recommendations, falling back to traditional method")
        traditional_results = traditional_friend_recommendations(limit - result.size)
        
        # Combine results, removing duplicates
        all_track_ids = result.map { |t| t[:id] }
        traditional_results['tracks'].each do |track|
          unless all_track_ids.include?(track[:id])
            result << track
            all_track_ids << track[:id]
            break if result.size >= limit
          end
        end
      end
      
      # Format result
      formatted_result = {
        'tracks' => result
      }
      
      # Cache the result
      Rails.cache.write(cache_key, formatted_result, expires_in: 1.day) if formatted_result.present?
      
      formatted_result
    rescue => e
      Rails.logger.error("Error in friend_based_recommendations: #{e.message}")
      
      # Last resort: fall back to traditional method
      Rails.logger.info("Embedding approach failed, falling back to traditional method")
      traditional_friend_recommendations(limit)
    end
  end
  
  # Traditional method for friend-based recommendations as a fallback
  private def traditional_friend_recommendations(limit)
    begin
      Rails.logger.info("Using traditional method for recommendations: returning friends' top tracks")
      
      all_friend_tracks = friends.flat_map do |friend| 
        begin
          # Try to get from friend's cache first
          friend_cache_key = "user:#{friend.id}:top_tracks:short_term"
          friend_top = Rails.cache.read(friend_cache_key)
          
          # If not in cache, fetch directly
          if friend_top.blank?
            friend_top = friend.get_top_tracks(limit: 10)
            # Cache the result if successful
            Rails.cache.write(friend_cache_key, friend_top, expires_in: 1.day) if friend_top.present?
          end
          
          # Process the tracks based on their format
          if friend_top.is_a?(Array)
            friend_top
          elsif friend_top && friend_top['items']
            friend_top['items']
          else
            []
          end
        rescue => e
          Rails.logger.error("Error in traditional method getting friend tracks: #{e.message}")
          []
        end
      end
      
      # Shuffle and take the requested number
      result = all_friend_tracks.shuffle.take(limit)
      
      # If we still don't have enough tracks, add our own top tracks
      if result.size < limit
        Rails.logger.info("Not enough friend tracks, adding own top tracks")
        own_tracks = get_top_tracks(limit: (limit - result.size))
        if own_tracks.is_a?(Array)
          result += own_tracks
        end
      end
      
      # Format result
      formatted_result = {
        'tracks' => result
      }
      
      formatted_result
    rescue => e
      Rails.logger.error("Error in traditional_friend_recommendations: #{e.message}")
      
      # Last resort: return our own top tracks
      Rails.logger.info("Traditional method failed, using own top tracks as last resort")
      {
        'tracks' => get_top_tracks(limit: limit)
      }
    end
  end
  
  # Get genre breakdown of user's music taste
  def genre_breakdown
    # Fetch top artists for the long term
    artists = get_top_artists(time_range: 'long_term', limit: 50)
    return {} if artists.empty?
    
    # Collect all genres from top artists (using symbol key)
    genres = artists.flat_map { |artist| artist[:genres] || [] }
    
    # Count occurrences
    genre_counts = Hash.new(0)
    genres.each { |genre| genre_counts[genre] += 1 }
    
    # Calculate percentages
    total = genre_counts.values.sum.to_f
    return {} if total == 0
    
    genre_counts.transform_values { |count| ((count / total) * 100).round(1) }
                .sort_by { |_, percentage| -percentage }
                .to_h
  end
  
  # Get users with similar music taste
  def find_similar_users(min_score: 50, limit: 10)
    # This method should be optimized for larger user bases
    # For a small application, this approach works fine
    
    # Get all users except self
    other_users = User.where.not(id: id)
    
    # Calculate compatibility with each user
    user_scores = other_users.map do |user|
      score = musical_compatibility_with(user)
      { user: user, score: score }
    end
    
    # Filter by minimum score and sort by highest compatibility
    user_scores.select { |item| item[:score] >= min_score }
              .sort_by { |item| -item[:score] }
              .take(limit)
  end
  
  #-----------------------
  # Anthem Track Method
  #-----------------------

  def update_anthem_track!
    # Ensure Spotify connection exists
    return unless spotify_access_token.present?

    # Fetch top track (long term, limit 1)
    response = spotify_api_call("me/top/tracks", params: { time_range: 'long_term', limit: 1 })
    
    # Check if response is valid and has items
    unless response && response['items'].is_a?(Array) && response['items'].any?
      Rails.logger.warn("No top tracks found for user #{id} when fetching anthem.")
      return
    end

    # Extract track data from the first item
    track_data = response['items'].first
    spotify_track_id = track_data['id']

    # Find or create the Track record
    track = Track.find_or_create_by(spotify_id: spotify_track_id) do |new_track|
      new_track.song_name = track_data['name']
      new_track.artist = track_data['artists']&.map { |a| a['name'] }&.join(', ')
      new_track.image_url = track_data['album']&.[]('images')&.first&.[]('url')
      new_track.preview_url = track_data['preview_url']
    end

    # Update the user's anthem track if it's different or not set
    if track.persisted? && self.anthem_track_id != track.id
      self.update(anthem_track_id: track.id)
      Rails.logger.info("Updated anthem track for user #{id} to track #{track.id} (#{track.song_name})")
    end

  rescue => e
    Rails.logger.error("Error fetching/updating anthem track for user #{id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
  end
  
  #-----------------------
  # Friendship Methods
  #-----------------------
  
  # Send a friend request
  def send_friend_request(other_user)
    return false if self == other_user
    return false if friends.include?(other_user)
    return false if friendships.where(friend: other_user).exists?
    
    friendships.create(friend: other_user, status: :pending)
  end
  
  # Accept a friend request
  def accept_friend_request(other_user)
    friendship = received_friendships.find_by(user: other_user, status: :pending)
    return false unless friendship
    
    friendship.update(status: :accepted)
    true
  end
  
  # Reject a friend request
  def reject_friend_request(other_user)
    friendship = received_friendships.find_by(user: other_user, status: :pending)
    return false unless friendship
    
    friendship.update(status: :rejected)
    true
  end
  
  # Remove a friend
  def remove_friend(other_user)
    friendship = friendships.find_by(friend: other_user, status: :accepted)
    reverse_friendship = received_friendships.find_by(user: other_user, status: :accepted)
    
    if friendship
      friendship.destroy
      return true
    elsif reverse_friendship
      reverse_friendship.destroy
      return true
    end
    
    false
  end
  
  # Get pending friend requests sent by this user
  def pending_friend_requests
    friendships.where(status: :pending)
  end
  
  # Get pending friend requests received by this user
  def friend_requests
    received_friendships.where(status: :pending)
  end
  
  # Check if users are friends
  def friends_with?(other_user)
    friends.include?(other_user)
  end
  
  # Get mutual friends with another user
  def mutual_friends_with(other_user)
    friends & other_user.friends
  end
  
  # Get friendship status with another user
  def friendship_status_with(other_user)
    # Check if there's a friendship record in either direction
    friendship = friendships.find_by(friend: other_user)
    reverse_friendship = received_friendships.find_by(user: other_user)
    
    if friendship
      return { status: friendship.status, direction: :outgoing }
    elsif reverse_friendship
      return { status: reverse_friendship.status, direction: :incoming }
    else
      return { status: :none, direction: nil }
    end
  end
  
  # Get all users who might be suggested as friends (friends of friends)
  def friend_suggestions(limit: 10)
    # Get all friends of friends
    potential_friends = friends.flat_map do |friend|
      friend.friends
    end
    
    # Remove duplicates and existing friends
    potential_friends = potential_friends.uniq - [self] - friends.to_a
    
    # Count mutual friends for each potential friend
    suggestions = potential_friends.map do |potential_friend|
      mutual_count = (friends & potential_friend.friends).size
      { user: potential_friend, mutual_friends_count: mutual_count }
    end
    
    # Sort by number of mutual friends and take the top ones
    suggestions.sort_by { |suggestion| -suggestion[:mutual_friends_count] }.take(limit)
  end
  
  # Check if this user is friends with another user
  def is_friend_with?(other_user)
    return false if other_user.nil? || other_user.id == self.id
    
    # Check both directions of friendship
    Friendship.where(user_id: self.id, friend_id: other_user.id, status: :accepted)
              .or(Friendship.where(user_id: other_user.id, friend_id: self.id, status: :accepted))
              .exists?
  end
  
  # Create a shared playlist with another user
  def create_shared_playlist_with(other_user)
    return nil unless is_friend_with?(other_user)
    
    # Verify both users have Spotify connected
    unless spotify_access_token.present?
      Rails.logger.error("Cannot create shared playlist: Current user has no Spotify access token")
      return nil
    end
    
    unless other_user.spotify_access_token.present?
      Rails.logger.error("Cannot create shared playlist: Other user has no Spotify access token")
      return nil
    end
    
    # Get top tracks from both users
    my_tracks = get_top_tracks(limit: 25)
    other_tracks = other_user.get_top_tracks(limit: 25)
    
    # Extract track URIs
    # The get_top_tracks method now returns an array of formatted track objects
    my_track_uris = my_tracks.is_a?(Array) ? my_tracks.map { |t| t[:uri] || t['uri'] } : []
    other_track_uris = other_tracks.is_a?(Array) ? other_tracks.map { |t| t[:uri] || t['uri'] } : []
    
    # Log for debugging
    Rails.logger.info("My track URIs (#{my_track_uris.size}): #{my_track_uris.inspect}")
    Rails.logger.info("Other user's track URIs (#{other_track_uris.size}): #{other_track_uris.inspect}")
    
    # Combine and shuffle tracks
    combined_tracks = (my_track_uris + other_track_uris).uniq.shuffle.take(50)
    
    # Ensure all track URIs are properly formatted
    combined_tracks = combined_tracks.map do |uri|
      uri.start_with?('spotify:track:') ? uri : "spotify:track:#{uri}"
    end
    
    Rails.logger.info("Combined track URIs (#{combined_tracks.size}): #{combined_tracks.inspect}")
    
    return nil if combined_tracks.empty?
    
    # Create a new playlist
    playlist_name = "Shared Vibes: #{self.display_name} & #{other_user.display_name}"
    playlist_description = "A shared playlist of tracks from #{self.display_name} and #{other_user.display_name}, created by Resonate. Anyone with this link can edit this playlist."
    
    begin
      # Create the playlist
      playlist_response = spotify_api_call(
        "users/#{spotify_id}/playlists", 
        method: :post,
        body: {
          name: playlist_name,
          description: playlist_description,
          public: false,
          collaborative: true
        }
      )
      
      # Check if playlist creation was successful
      if !playlist_response || !playlist_response['id']
        Rails.logger.error("Failed to create playlist: #{playlist_response.inspect}")
        return nil
      end
      
      playlist_id = playlist_response['id']
      Rails.logger.info("Successfully created playlist with ID: #{playlist_id}")
      
      # Make the playlist collaborative
      # Note: According to Spotify API, setting collaborative=true when creating the playlist
      # should be sufficient, but we'll ensure it's set properly here
      
      # Add tracks to the playlist
      if combined_tracks.any?
        # Add tracks in smaller batches (Spotify API limits)
        success = false
        
        # First try adding all tracks at once
        add_tracks_response = spotify_api_call(
          "playlists/#{playlist_id}/tracks",
          method: :post,
          body: {
            uris: combined_tracks
          }
        )
        
        if add_tracks_response && (add_tracks_response['snapshot_id'] || add_tracks_response['uri'])
          success = true
          Rails.logger.info("Successfully added all tracks at once: #{add_tracks_response.inspect}")
        else
          # If adding all at once fails, try adding in batches
          Rails.logger.warn("Failed to add all tracks at once, trying batches")
          success = true # Reset and assume success unless a batch fails
          
          combined_tracks.each_slice(10) do |track_batch|
            batch_response = spotify_api_call(
              "playlists/#{playlist_id}/tracks",
              method: :post,
              body: {
                uris: track_batch
              }
            )
            
            if !batch_response || (!batch_response['snapshot_id'] && !batch_response['uri'])
              Rails.logger.error("Failed to add track batch: #{batch_response.inspect}")
              success = false
              break
            end
            
            # Add a small delay between batch requests
            sleep(0.5)
          end
        end
        
        if !success
          Rails.logger.error("Failed to add tracks to playlist")
          return {
            id: playlist_id,
            name: playlist_response['name'],
            external_url: playlist_response['external_urls']['spotify'],
            track_count: 0,
            error: "Created playlist but failed to add tracks"
          }
        end
      end
      
      # Generate a share link for the other user
      share_url = playlist_response['external_urls']['spotify']
      
      # Log the share URL for the other user
      Rails.logger.info("Created collaborative playlist: #{share_url}")
      Rails.logger.info("Share this URL with #{other_user.display_name} to collaborate")
      
      # Return the playlist data
      {
        id: playlist_response['id'],
        name: playlist_response['name'],
        external_url: playlist_response['external_urls']['spotify'],
        track_count: combined_tracks.size,
        collaborative: true,
        shared_with: other_user.display_name
      }
    rescue => e
      Rails.logger.error("Error creating shared playlist: #{e.message}")
      nil
    end
  end
  
  # Music data caching to reduce API calls
  def cache_music_data!
    # This method can be called by a background job to periodically
    # fetch and store music data for faster access
    
    Rails.cache.write("user:#{id}:top_tracks:short_term", get_top_tracks, expires_in: 1.day)
    Rails.cache.write("user:#{id}:top_artists:short_term", get_top_artists, expires_in: 1.day)
    Rails.cache.write("user:#{id}:genre_breakdown", genre_breakdown, expires_in: 1.day)
    
    # More caching as needed
  end
  
  private
  
  def spotify_api_call(endpoint, method: :get, params: {}, body: nil)
    # Ensure token is fresh
    refresh_token_if_expired
    
    # Build the full URL
    url = "https://api.spotify.com/v1/#{endpoint}"
    
    Rails.logger.info("Making Spotify API call to: #{url} with params: #{params.inspect}")
    
    response = Faraday.new do |conn|
      conn.request :json
      conn.response :json
    end.send(method) do |req|
      req.url url
      req.headers['Authorization'] = "Bearer #{spotify_access_token}"
      req.params = params if params.present?
      req.body = body if body.present?
    end
    
    # Handle successful responses (200 OK or 201 Created)
    if response.status == 200 || response.status == 201
      Rails.logger.info("Spotify API call successful: #{endpoint} with status #{response.status}")
      response.body
    elsif response.status == 401
      Rails.logger.warn("Spotify API unauthorized (401): Attempting token refresh")
      # Force token refresh and retry once
      refresh_success = refresh_spotify_token!
      
      # If token refresh failed, return empty data
      unless refresh_success
        Rails.logger.error("Spotify token refresh failed")
        return method == :get ? {} : false
      end
      
      # Retry the request with fresh token
      Rails.logger.info("Retrying Spotify API call with refreshed token")
      response = Faraday.new do |conn|
        conn.request :json
        conn.response :json
      end.send(method) do |req|
        req.url url
        req.headers['Authorization'] = "Bearer #{spotify_access_token}"
        req.params = params if params.present?
        req.body = body if body.present?
      end
      
      # Check for success on retry (200 OK or 201 Created)
      if response.status == 200 || response.status == 201
        Rails.logger.info("Spotify API retry successful: #{endpoint} with status #{response.status}")
        response.body
      else
        Rails.logger.error("Spotify API error after token refresh: #{response.status} - #{response.body.inspect}")
        method == :get ? {} : false
      end
    elsif response.status == 404
      Rails.logger.error("Spotify API 404 Not Found: #{url} - Response: #{response.body.inspect}")
      method == :get ? {} : false
    else
      Rails.logger.error("Spotify API error: #{response.status} - URL: #{url} - Response: #{response.body.inspect}")
      method == :get ? {} : false
    end
  end
  
  def refresh_token_if_expired
    return true unless spotify_token_expired?
    refresh_spotify_token!
  end
  
  def spotify_token_expired?
    spotify_token_expires_at.nil? || spotify_token_expires_at < Time.current
  end
  
  def refresh_spotify_token!
    # Check if refresh token exists
    unless spotify_refresh_token.present?
      Rails.logger.error("Cannot refresh Spotify token: No refresh token available")
      return false
    end
    
    # You'll need to set these in your environment or credentials
    client_id = ENV['SPOTIFY_CLIENT_ID']
    client_secret = ENV['SPOTIFY_CLIENT_SECRET']
    
    begin
      response = Faraday.new(url: 'https://accounts.spotify.com/api/token') do |conn|
        conn.request :url_encoded
        conn.response :json
      end.post do |req|
        req.headers['Authorization'] = "Basic #{Base64.strict_encode64("#{client_id}:#{client_secret}")}"
        req.headers['Content-Type'] = 'application/x-www-form-urlencoded'
        req.body = {
          grant_type: 'refresh_token',
          refresh_token: spotify_refresh_token
        }
      end
      
      if response.status == 200
        update(
          spotify_access_token: response.body['access_token'],
          spotify_token_expires_at: Time.current + response.body['expires_in'].seconds
        )
        
        # If a new refresh token is provided, update that too
        if response.body['refresh_token'].present?
          update(spotify_refresh_token: response.body['refresh_token'])
        end
        
        true
      else
        Rails.logger.error("Failed to refresh Spotify token: #{response.status} - #{response.body}")
        false
      end
    rescue => e
      Rails.logger.error("Exception during Spotify token refresh: #{e.message}")
      false
    end
  end
  
  def time_range_for_depth(depth)
    case depth
    when :shallow then 'short_term'  # Recent 4 weeks
    when :medium then 'medium_term'  # Last 6 months (default)
    when :deep then 'long_term'      # Several years
    else 'short_term'
    end
  end
  
  def calculate_feature_similarity(my_features, their_features)
    return 0 if my_features.empty? || their_features.empty?
    
    # Features to compare
    compared_features = %w[danceability energy valence acousticness instrumentalness tempo]
    
    # Calculate averages for each feature
    my_averages = calculate_feature_averages(my_features, compared_features)
    their_averages = calculate_feature_averages(their_features, compared_features)
    
    # Calculate distance between feature vectors (normalized)
    total_difference = 0
    feature_count = 0
    
    compared_features.each do |feature|
      # Skip if either average is nil
      next unless my_averages[feature] && their_averages[feature]
      
      # For tempo, we need to normalize the values
      if feature == 'tempo'
        # Normalize tempo to 0-1 range (assuming most tempo values fall between 60-180 BPM)
        my_norm = normalize_tempo(my_averages[feature])
        their_norm = normalize_tempo(their_averages[feature])
        total_difference += (my_norm - their_norm).abs
      else
        # Calculate absolute difference (other features are already 0-1)
        total_difference += (my_averages[feature] - their_averages[feature]).abs
      end
      
      feature_count += 1
    end
    
    # Avoid division by zero
    return 0 if feature_count == 0
    
    # Convert distance to similarity (0 to 1 scale)
    1 - (total_difference / feature_count)
  end
  
  def normalize_tempo(tempo)
    # Normalize tempo to 0-1 range
    # Most songs are between 60-180 BPM
    min_tempo = 60
    max_tempo = 180
    
    normalized = (tempo - min_tempo) / (max_tempo - min_tempo)
    [0, [1, normalized].min].max  # Clamp to 0-1 range
  end
  
  def calculate_feature_averages(features, feature_names)
    valid_features = features.reject { |f| f.nil? }
    total_tracks = valid_features.size.to_f
    return {} if total_tracks.zero?
    
    # Sum all features
    sums = Hash.new(0)
    count = Hash.new(0)
    
    valid_features.each do |track_features|
      feature_names.each do |feature|
        if track_features && track_features[feature]
          sums[feature] += track_features[feature].to_f
          count[feature] += 1
        end
      end
    end
    
    # Calculate averages
    averages = {}
    feature_names.each do |feature|
      averages[feature] = count[feature] > 0 ? sums[feature] / count[feature] : nil
    end
    
    averages
  end
  
  def format_tracks_response(response)
    return [] unless response && response['items'].is_a?(Array)
    
    response['items'].map do |track|
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
  end
  
  def format_artists_response(response)
    return [] unless response && response['items'].is_a?(Array)
    
    response['items'].map do |artist|
      {
        id: artist['id'],
        name: artist['name'],
        image_url: artist['images'].first&.dig('url'),
        genres: artist['genres'],
        popularity: artist['popularity'],
        uri: artist['uri']
      }
    end
  end
end
