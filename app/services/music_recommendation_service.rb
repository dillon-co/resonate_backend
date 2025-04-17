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
    # Get user's existing track IDs to exclude
    user_track_ids = user.tracks.pluck(:id)
    
    # Find tracks with embeddings
    tracks_with_embeddings = TrackFeature.where.not(embedding: nil)
                                        .where.not(track_id: user_track_ids)
                                        .includes(:track)
    
    return [] if tracks_with_embeddings.empty?
    
    # Create a Neighbor index with track embeddings
    track_index = Neighbor::Index.new(dimensions: user.embedding.size, metric: :cosine)
    
    # Add track embeddings to the index
    tracks_with_embeddings.each do |track_feature|
      track_index.add(track_feature.id, track_feature.embedding)
    end
    
    # Find nearest neighbors
    nearest_neighbors = track_index.nearest_neighbors(user.embedding, k: limit * 2)
    
    # Convert to track objects
    recommended_tracks = []
    nearest_neighbors.each do |neighbor_id, _distance|
      track_feature = tracks_with_embeddings.find { |tf| tf.id == neighbor_id }
      next unless track_feature&.track
      
      track = track_feature.track
      recommended_tracks << {
        id: track.spotify_id,
        name: track.song_name,
        artist: track.artist,
        album_art_url: track.image_url,
        popularity: 0, # We don't have this data, so default to 0
        preview_url: nil, # We don't have this data
        uri: "spotify:track:#{track.spotify_id}"
      }
      
      break if recommended_tracks.size >= limit
    end
    
    recommended_tracks
  end
  
  # Get artist recommendations using embedding similarity
  def self.get_artist_recommendations_by_embedding(user, limit)
    # Get user's existing artist IDs to exclude
    user_artist_ids = user.artists.pluck(:id)
    
    # Find artists with embeddings
    artists_with_embeddings = ArtistFeature.where.not(embedding: nil)
                                          .where.not(artist_id: user_artist_ids)
                                          .includes(:artist)
    
    return [] if artists_with_embeddings.empty?
    
    # Create a Neighbor index with artist embeddings
    artist_index = Neighbor::Index.new(dimensions: user.embedding.size, metric: :cosine)
    
    # Add artist embeddings to the index
    artists_with_embeddings.each do |artist_feature|
      artist_index.add(artist_feature.id, artist_feature.embedding)
    end
    
    # Find nearest neighbors
    nearest_neighbors = artist_index.nearest_neighbors(user.embedding, k: limit * 2)
    
    # Convert to artist objects
    recommended_artists = []
    nearest_neighbors.each do |neighbor_id, _distance|
      artist_feature = artists_with_embeddings.find { |af| af.id == neighbor_id }
      next unless artist_feature&.artist
      
      artist = artist_feature.artist
      recommended_artists << artist
      
      break if recommended_artists.size >= limit
    end
    
    recommended_artists
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
