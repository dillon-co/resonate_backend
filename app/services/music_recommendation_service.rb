class MusicRecommendationService
  # TasteDive API configuration
  TASTEDIVE_API_KEY = ENV['TASTEDIVE_API_KEY']
  TASTEDIVE_API_URL = 'https://tastedive.com/api/similar'
  
  # Get recommendations based on a list of tracks
  def self.get_recommendations(tracks, limit: 20)
    # Cache key based on track IDs
    track_ids = tracks.map { |t| t[:id] || t['id'] }.compact.join('-')
    cache_key = "recommendations:#{track_ids}:#{limit}"
    
    # Try to get from cache first
    cached_recommendations = Rails.cache.read(cache_key)
    return cached_recommendations if cached_recommendations.present?
    
    # Extract track and artist info
    track_info = extract_track_info(tracks)
    
    # Try to get recommendations from TasteDive
    recommended_artists_and_tracks = get_tastedive_recommendations(track_info, limit)
    
    # If TasteDive fails, use a fallback method based on genre and popularity
    if recommended_artists_and_tracks.blank?
      Rails.logger.info("TasteDive recommendations failed, using fallback recommendation method")
      recommended_artists_and_tracks = generate_fallback_recommendations(track_info, limit)
    end
    
    # Convert recommendations to Spotify format
    spotify_formatted_tracks = recommended_artists_and_tracks.present? ? 
                               convert_to_spotify_format(recommended_artists_and_tracks) : []
    
    # Cache the result
    result = {
      'tracks' => spotify_formatted_tracks
    }
    
    Rails.cache.write(cache_key, result, expires_in: 1.day)
    result
  end
  
  # Get recommendations for a user based on their top tracks
  def self.get_recommendations_for_user(user, limit: 20, time_range: 'short_term')
    # Get user's top tracks
    top_tracks = user.get_top_tracks(time_range: time_range, limit: 50)
    top_tracks = top_tracks.is_a?(Array) ? top_tracks : []
    
    # If no top tracks, return empty result
    return { 'tracks' => [] } if top_tracks.empty?
    
    # Use a subset of top tracks to get more diverse recommendations
    seed_tracks = top_tracks.sample([top_tracks.size, 5].min)
    
    # Get recommendations
    get_recommendations(seed_tracks, limit: limit)
  end
  
  # Get recommendations based on a list of artists
  def self.get_recommendations_from_artists(artists, limit: 20)
    # Cache key based on artist IDs
    artist_ids = artists.map { |a| a[:id] || a['id'] }.compact.join('-')
    cache_key = "artist_recommendations:#{artist_ids}:#{limit}"
    
    # Try to get from cache first
    cached_recommendations = Rails.cache.read(cache_key)
    return cached_recommendations if cached_recommendations.present?
    
    # Extract artist names
    artist_names = artists.map do |artist|
      artist[:name] || artist['name']
    end.compact
    
    # Get recommendations from TasteDive
    recommended_artists = get_tastedive_recommendations_for_artists(artist_names, limit)
    
    # Convert recommendations to Spotify format
    spotify_formatted_tracks = convert_artists_to_spotify_tracks(recommended_artists)
    
    # Cache the result
    result = {
      'tracks' => spotify_formatted_tracks
    }
    
    Rails.cache.write(cache_key, result, expires_in: 1.day)
    result
  end
  
  # Get recommendations for a user based on their embedding
  def self.get_embedding_recommendations_for_user(user, limit: 20)
    # Ensure user has an embedding
    unless user.embedding.present?
      # Generate embedding if not present

      UserEmbeddingService.update_embedding_for(user) unless user.embedding.present?
      
      # If still no embedding, fall back to regular recommendations
      unless user.embedding.present?
        Rails.logger.warn("Could not generate embedding for user #{user.id}, falling back to regular recommendations")
        return get_recommendations(user.tracks.limit(10), limit: limit)
      end
    end
    
    # Cache key based on user ID and embedding updated timestamp
    cache_key = "user_embedding_recommendations:#{user.id}:#{user.updated_at.to_i}:#{limit}"
    
    # Try to get from cache first
    cached_recommendations = Rails.cache.read(cache_key)
    return cached_recommendations if cached_recommendations.present?
    
    # Get recommendations using embeddings
    recommended_tracks = get_track_recommendations_by_embedding(user, limit)
    
    # If we couldn't get enough recommendations, supplement with artist recommendations
    if recommended_tracks.size < limit
      remaining = limit - recommended_tracks.size
      recommended_artists = get_artist_recommendations_by_embedding(user, remaining * 2)
      
      # Get top tracks from recommended artists
      artist_tracks = get_top_tracks_from_artists(recommended_artists, remaining)
      
      # Combine recommendations, removing duplicates
      all_track_ids = recommended_tracks.map { |t| t[:id] }
      artist_tracks.each do |track|
        unless all_track_ids.include?(track[:id])
          recommended_tracks << track
          all_track_ids << track[:id]
          break if recommended_tracks.size >= limit
        end
      end
    end
    
    # Format result
    result = {
      'tracks' => recommended_tracks
    }
    
    # Cache the result
    Rails.cache.write(cache_key, result, expires_in: 1.day)
    result
  end
  
  # Get track recommendations using embedding similarity
  def self.get_track_recommendations_by_embedding(user, limit)
    Rails.logger.info "Getting track recommendations by embedding for user #{user.id}"
    # Get user's existing track IDs to exclude
    user_track_ids = user.track_ids # Use association directly
    
    # Find tracks with embeddings, excluding those the user already has
    tracks_with_embeddings = TrackFeature.includes(:track).where.not(embedding: nil)
    tracks_with_embeddings = tracks_with_embeddings.where.not(track_id: user_track_ids) if user_track_ids.present?
    
    return [] if tracks_with_embeddings.empty? || user.embedding.blank?
    
    # Calculate similarities
    similarities = tracks_with_embeddings.map do |track_feature|
      similarity = cosine_similarity(user.embedding, track_feature.embedding)
      { feature: track_feature, similarity: similarity }
    end
    
    # Sort by similarity (descending)
    sorted_tracks = similarities.sort_by { |item| -item[:similarity] }
    
    # Convert to track objects and take limit
    recommended_tracks = []
    sorted_tracks.take(limit).each do |item|
      track_feature = item[:feature]
      track = track_feature.track
      next unless track
      
      recommended_tracks << {
        id: track.spotify_id,
        name: track.song_name,
        artist: track.artist,
        album_art_url: track.image_url,
        popularity: track_feature.popularity || 0, # Use popularity from TrackFeature
        preview_url: track.preview_url, # Use stored preview URL if available
        uri: "spotify:track:#{track.spotify_id}"
      }
    end
    
    Rails.logger.info "Found #{recommended_tracks.size} track recommendations for user #{user.id}"
    recommended_tracks.uniq
  end
  
  # Get artist recommendations using embedding similarity
  def self.get_artist_recommendations_by_embedding(user, limit)
    Rails.logger.info "Getting artist recommendations by embedding for user #{user.id}"
    # Get user's existing artist IDs to exclude
    user_artist_ids = user.artist_ids # Use the association directly
    
    # Find artists with embeddings, excluding those the user already follows/listens to
    artists_with_embeddings = ArtistFeature.includes(:artist).where.not(embedding: nil)
    artists_with_embeddings = artists_with_embeddings.where.not(artist_id: user_artist_ids) if user_artist_ids.present?
    
    return [] if artists_with_embeddings.empty? || user.embedding.blank?
    
    # Calculate similarities
    similarities = artists_with_embeddings.map do |artist_feature|
      similarity = cosine_similarity(user.embedding, artist_feature.embedding)
      { feature: artist_feature, similarity: similarity }
    end
    
    # Sort by similarity (descending)
    sorted_artists = similarities.sort_by { |item| -item[:similarity] }
    
    # Convert to artist objects and take limit
    recommended_artists = []
    sorted_artists.take(limit).each do |item|
      artist_feature = item[:feature]
      artist = artist_feature.artist
      next unless artist
      
      recommended_artists << {
        id: artist.spotify_id,
        name: artist.name
        # Add other fields if needed, e.g., image_url from artist model
      }
    end
    
    Rails.logger.info "Found #{recommended_artists.size} artist recommendations for user #{user.id}"
    recommended_artists
  end
  
  # Helper method for cosine similarity (copied from MusicCompatibilityService)
  def self.cosine_similarity(vec1, vec2)
    return 0 unless vec1.is_a?(Array) && vec2.is_a?(Array) && vec1.size == vec2.size && vec1.size > 0

    dot_product = 0
    norm1 = 0
    norm2 = 0

    vec1.zip(vec2).each do |v1, v2|
      # Ensure values are numeric
      v1_num = v1.to_f
      v2_num = v2.to_f
      
      dot_product += v1_num * v2_num
      norm1 += v1_num**2
      norm2 += v2_num**2
    end

    return 0 if norm1 == 0 || norm2 == 0

    similarity = dot_product / (Math.sqrt(norm1) * Math.sqrt(norm2))
    
    # Clamp similarity to range [-1, 1] to avoid potential floating point issues
    [[similarity, -1.0].max, 1.0].min 
  end
  
  # Get top tracks from a list of artists
  def self.get_top_tracks_from_artists(artists, limit)
    tracks = []
    
    artists.each do |artist|
      # Try to find tracks by this artist in our database
      artist_tracks = Track.where("artist ILIKE ?", "%#{artist.name}%").limit(3)
      
      artist_tracks.each do |track|
        tracks << {
          id: track.spotify_id,
          name: track.song_name,
          artist: track.artist,
          album_art_url: track.image_url,
          popularity: 0, # We don't have this data, so default to 0
          preview_url: nil, # We don't have this data
          uri: "spotify:track:#{track.spotify_id}"
        }
        
        break if tracks.size >= limit
      end
      
      break if tracks.size >= limit
    end
    
    tracks
  end
  
  private
  
  # Extract track and artist info
  def self.extract_track_info(tracks)
    tracks.map do |track|
      {
        name: track[:name] || track['name'],
        artist: extract_artist_name(track)
      }
    end
  end
  
  # Extract artist name from track
  def self.extract_artist_name(track)
    artists = track[:artists] || track['artists'] || []
    
    if artists.empty?
      # Try to get from artist field directly
      return track[:artist][:name] if track[:artist]&.is_a?(Hash) && track[:artist][:name]
      return track['artist']['name'] if track['artist']&.is_a?(Hash) && track['artist']['name']
      return track[:artist] || track['artist']
    end
    
    # Get first artist name
    first_artist = artists.first
    return first_artist[:name] if first_artist.is_a?(Hash) && first_artist[:name]
    return first_artist['name'] if first_artist.is_a?(Hash) && first_artist['name']
    first_artist.to_s
  end
  
  # Get recommendations from TasteDive based on tracks
  def self.get_tastedive_recommendations(track_info, limit)
    # Log the input for debugging
    Rails.logger.info("Getting TasteDive recommendations for tracks: #{track_info.inspect}")
    
    # Prepare a better formatted query for TasteDive
    # Use only the first track to increase chances of getting results
    if track_info.present?
      first_track = track_info.first
      artist = first_track[:artist] || first_track['artist']
      
      # Format query as just the artist name with plus signs for spaces
      # This format has been confirmed to work with the TasteDive API
      query = artist.gsub(' ', '+')
      
      Rails.logger.info("Using artist-only query for TasteDive: #{query}")
      
      # Get recommendations using the simplified query
      results = get_tastedive_similar_items(query, 'music', limit)
      
      if results.present?
        Rails.logger.info("TasteDive returned #{results.size} results")
        return results
      else
        Rails.logger.warn("TasteDive returned no results for query: #{query}")
        
        # Try with a different artist if available
        if track_info.size > 1
          second_track = track_info[1]
          second_artist = second_track[:artist] || second_track['artist']
          second_query = second_artist.gsub(' ', '+')
          
          Rails.logger.info("Trying second artist query for TasteDive: #{second_query}")
          second_results = get_tastedive_similar_items(second_query, 'music', limit)
          
          if second_results.present?
            Rails.logger.info("TasteDive returned #{second_results.size} results for second artist")
            return second_results
          end
        end
      end
    end
    
    # Return empty array if no results
    []
  end
  
  # Get recommendations from TasteDive based on artists
  def self.get_tastedive_recommendations_for_artists(artist_names, limit)
    # Log the input for debugging
    Rails.logger.info("Getting TasteDive recommendations for artists: #{artist_names.inspect}")
    
    # For simplicity, just use the first artist as a seed
    # This is a temporary solution to get the API working
    if artist_names.present?
      first_artist = artist_names.first
      
      # Format query as just the artist name with plus signs for spaces
      # This format has been confirmed to work with the TasteDive API
      query = first_artist.gsub(' ', '+')
      
      Rails.logger.info("Using artist-only query for TasteDive: #{query}")
      
      # Get recommendations using the simplified query
      results = get_tastedive_similar_items(query, 'music', limit)
      
      if results.present?
        Rails.logger.info("TasteDive returned #{results.size} results")
        return convert_artists_to_spotify_tracks(results)
      else
        Rails.logger.warn("TasteDive returned no results for query: #{query}")
      end
    end
    
    # Return empty array if no results
    []
  end
  
  # Call TasteDive API to get similar items
  def self.get_tastedive_similar_items(query, type, limit)
    return [] if query.blank?
    
    begin
      # Log the request parameters
      Rails.logger.info("TasteDive API request: query='#{query}', type='#{type}', limit=#{limit}")
      
      # Make TasteDive API call - using the exact same format that worked in our test
      response = Faraday.get(TASTEDIVE_API_URL, {
        q: query,
        type: type,
        limit: limit,
        k: TASTEDIVE_API_KEY,
        info: 1
      })
      
      # Log the response status and body
      Rails.logger.info("TasteDive API response status: #{response.status}")
      Rails.logger.info("TasteDive API response body: #{response.body}")
      
      if response.status == 200
        data = JSON.parse(response.body)
        
        if data['Similar'] && data['Similar']['Results'] && data['Similar']['Results'].any?
          Rails.logger.info("TasteDive API returned #{data['Similar']['Results'].size} results")
          return data['Similar']['Results']
        else
          Rails.logger.warn("TasteDive API returned 200 but no results in the response: #{data.inspect}")
        end
      else
        Rails.logger.error("TasteDive API error: #{response.status} - #{response.body}")
      end
      
      []
    rescue => e
      Rails.logger.error("Error calling TasteDive API: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      []
    end
  end
  
  # Convert TasteDive recommendations to Spotify format
  def self.convert_to_spotify_format(recommendations)
    recommendations.map do |item|
      # Parse artist and track from name (if it's in "Artist - Track" format)
      # The API docs and our test show that items should be separated by commas
      name_parts = item['Name'].split(' - ', 2)
      
      if name_parts.size == 2
        artist_name = name_parts[0]
        track_name = name_parts[1]
      else
        # If it's just an artist name
        artist_name = item['Name']
        track_name = "Top track by #{artist_name}"
      end
      
      # Create a Spotify-like track object
      {
        'id' => generate_id_from_name(item['Name']),
        'name' => track_name,
        'artists' => [
          {
            'id' => generate_id_from_name(artist_name),
            'name' => artist_name
          }
        ],
        'album' => {
          'id' => generate_id_from_name("album_#{item['Name']}"),
          'name' => "Album by #{artist_name}",
          'images' => []
        },
        'popularity' => 50, # Default popularity
        'preview_url' => nil,
        'external_urls' => {
          'spotify' => "https://open.spotify.com/search/#{URI.encode_www_form_component(item['Name'])}"
        }
      }
    end
  end
  
  # Convert artist recommendations to Spotify track format
  def self.convert_artists_to_spotify_tracks(artist_recommendations)
    artist_recommendations.map do |item|
      artist_name = item['Name']
      
      # Create a Spotify-like track object
      {
        'id' => generate_id_from_name("track_by_#{artist_name}"),
        'name' => "Popular track by #{artist_name}",
        'artists' => [
          {
            'id' => generate_id_from_name(artist_name),
            'name' => artist_name
          }
        ],
        'album' => {
          'id' => generate_id_from_name("album_by_#{artist_name}"),
          'name' => "Album by #{artist_name}",
          'images' => []
        },
        'popularity' => 50, # Default popularity
        'preview_url' => nil,
        'external_urls' => {
          'spotify' => "https://open.spotify.com/search/#{URI.encode_www_form_component(artist_name)}"
        }
      }
    end
  end
  
  # Generate a deterministic ID from a name
  def self.generate_id_from_name(name)
    Digest::MD5.hexdigest(name)[0...22]
  end
  
  # Fallback method to search Spotify for a track
  def self.search_spotify_for_track(user, track_name, artist_name)
    query = "track:#{track_name} artist:#{artist_name}"
    
    begin
      response = user.spotify_api_call('search', params: {
        q: query,
        type: 'track',
        limit: 1
      })
      
      if response && response['tracks'] && response['tracks']['items'] && response['tracks']['items'].any?
        return response['tracks']['items'].first
      end
    rescue => e
      Rails.logger.error("Error searching Spotify: #{e.message}")
    end
    
    nil
  end
end
