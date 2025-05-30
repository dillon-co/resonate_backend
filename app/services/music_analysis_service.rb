class MusicAnalysisService
  # Deezer API configuration
  API_ROOT = 'https://api.deezer.com'
  
  # Process a track and save its features
  def self.process_track(track)
    return nil unless track.is_a?(Track) && track.persisted?
    
    # Check if features already exist
    existing_features = TrackFeature.find_by(track_id: track.id)
    return existing_features if existing_features.present?
    
    # Get track data from Deezer
    track_data = get_track_data(track.song_name, track.artist)
    
    # Log if we got empty features
    if track_data == default_features
      Rails.logger.warn("Failed to get features for track: #{track.song_name} by #{track.artist}")
      # Determine era from artist data
  def self.era_from_artist(features)
    # This is a guess since Deezer doesn't provide this info directly
    # Would need more data to make a better guess
    "contemporary"
  end
  
  # Determine era from release date
  def self.era_from_release_date(release_date)
    return "unknown" unless release_date
    
    year = Date.parse(release_date).year rescue nil
    return "unknown" unless year
    
    case year
    when 0..1959
      "classic"
    when 1960..1979
      "60s-70s"
    when 1980..1999
      "80s-90s"
    when 2000..2010
      "2000s"
    else
      "contemporary"
    end
  end
  
  # Extract themes from genres
  def self.themes_from_genres(genres)
    return nil unless genres&.any?
    
    themes = []
    
    genres.each do |genre|
      case genre&.downcase
      when "rock"
        themes << "rebellion" << "freedom"
      when "pop"
        themes << "love" << "relationships"
      when "hip hop", "rap"
        themes << "urban life" << "social commentary"
      when "electronic", "dance"
        themes << "celebration" << "escape"
      when "jazz"
        themes << "sophistication" << "improvisation"
      when "classical"
        themes << "emotion" << "storytelling"
      when "country"
        themes << "heartbreak" << "rural life"
      when "r&b", "soul"
        themes << "love" << "emotion"
      end
    end
    
    themes.uniq.join(", ")
  end
  
  # Determine energy level from features
  def self.energy_level_from_features(features)
    return 3 unless features && features[:energy]
    
    case features[:energy]
    when 0.0..0.3
      1
    when 0.3..0.5
      2
    when 0.5..0.7
      3
    when 0.7..0.9
      4
    when 0.9..1.0
      5
    else
      3
    end
  end
  
  # Get detailed artist data
  def self.get_detailed_artist_data(artist_id)
    begin
      response = Faraday.get("#{API_ROOT}/artist/#{artist_id}")
      
      if response.status == 200
        artist_data = JSON.parse(response.body)
        
        # Get artist's top tracks
        top_tracks = get_artist_top_tracks(artist_id)
        
        # Calculate features from top tracks
        features = {}
        if top_tracks.any?
          # Get features for top tracks to estimate artist features
          track_features = top_tracks.map { |t| get_track_data(t[:title], artist_data['name']) }
          avg_features = calculate_overall_features(track_features)
          features = avg_features
        end
        
        return {
          id: artist_data['id'],
          name: artist_data['name'],
          link: artist_data['link'],
          picture: artist_data['picture_xl'],
          nb_album: artist_data['nb_album'],
          nb_fan: artist_data['nb_fan'],
          radio: artist_data['radio'],
          tracklist: artist_data['tracklist'],
          top_tracks: top_tracks,
          genres: [], # Deezer doesn't provide artist genres directly
          **features
        }
      end
      
      {}
    rescue => e
      Rails.logger.error("Error getting detailed artist data: #{e.message}")
      {}
    end
  end
  
  # Get artist's top tracks
  def self.get_artist_top_tracks(artist_id, limit = 5)
    begin
      response = Faraday.get("#{API_ROOT}/artist/#{artist_id}/top") do |req|
        req.params = { limit: limit }
      end
      
      if response.status == 200
        data = JSON.parse(response.body)
        
        if data['data']
          return data['data'].map do |track|
            {
              id: track['id'],
              title: track['title'],
              duration: track['duration'],
              preview: track['preview']
            }
          end
        end
      end
      
      []
    rescue => e
      Rails.logger.error("Error getting artist top tracks: #{e.message}")
      []
    end
  end
  
  # Get detailed album data
  def self.get_detailed_album_data(album_id)
    begin
      response = Faraday.get("#{API_ROOT}/album/#{album_id}")
      
      if response.status == 200
        album_data = JSON.parse(response.body)
        
        # Extract tracks
        tracks = []
        if album_data['tracks'] && album_data['tracks']['data']
          tracks = album_data['tracks']['data'].map do |track|
            {
              id: track['id'],
              title: track['title'],
              duration: track['duration'],
              preview: track['preview']
            }
          end
        end
        
        # Extract genres
        genres = []
        if album_data['genres'] && album_data['genres']['data']
          genres = album_data['genres']['data'].map { |genre| genre['name'] }
        elsif album_data['genre_id']
          genre_name = get_genre_name(album_data['genre_id'])
          genres = [genre_name] if genre_name
        end
        
        # Calculate album features from tracks
        features = {}
        if tracks.any? && album_data['artist']
          # Sample a few tracks to estimate album features
          sample_tracks = tracks.first(3)
          track_features = sample_tracks.map { |t| get_track_data(t[:title], album_data['artist']['name']) }
          avg_features = calculate_overall_features(track_features)
          features = avg_features
        end
        
        return {
          id: album_data['id'],
          title: album_data['title'],
          upc: album_data['upc'],
          link: album_data['link'],
          cover: album_data['cover_xl'],
          genre_id: album_data['genre_id'],
          genres: genres,
          label: album_data['label'],
          nb_tracks: album_data['nb_tracks'],
          duration: album_data['duration'],
          fans: album_data['fans'],
          release_date: album_data['release_date'],
          tracks: tracks,
          artist: {
            id: album_data['artist']['id'],
            name: album_data['artist']['name']
          },
          **features
        }
      end
      
      {}
    rescue => e
      Rails.logger.error("Error getting detailed album data: #{e.message}")
      {}
    end
  end
  
  # Prepare track data for Deezer API
  def self.prepare_track_data(tracks)
    tracks.map do |track|
      {
        id: track[:id] || track['id'],
        name: track[:name] || track['name'],
        artist_name: extract_artist_name(track)
      }.compact
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
  
  # Calculate overall features from individual track features
  def self.calculate_overall_features(features_list)
    return default_features if features_list.empty?
    
    # Calculate average for numeric features
    numeric_features = [:energy, :mood, :danceability, :acousticness, :popularity]
    
    overall = {}
    numeric_features.each do |feature|
      values = features_list.map { |f| f[feature] }.compact
      overall[feature] = values.empty? ? 0.5 : values.sum / values.size.to_f
    end
    
    # Collect all tags
    all_tags = features_list.flat_map { |f| f[:tags] || [] }.compact
    
    # Count tag occurrences
    tag_counts = Hash.new(0)
    all_tags.each { |tag| tag_counts[tag] += 1 }
    
    # Get top tags
    top_tags = tag_counts.sort_by { |_, count| -count }.take(10).map(&:first)
    overall[:tags] = top_tags
    
    # Determine overall genre
    genres = features_list.map { |f| f[:genre] }.compact
    if genres.any?
      genre_counts = Hash.new(0)
      genres.each { |genre| genre_counts[genre] += 1 }
      overall[:genre] = genre_counts.max_by { |_, count| count }&.first
    end
    
    overall
  end
    
    # Save features to database (even if default)
    save_track_features(track, track_data)
  end
  
  # Process an artist and save its features
  def self.process_artist(artist)
    return nil unless artist.is_a?(Artist) && artist.persisted?
    
    # Check if features already exist
    existing_features = ArtistFeature.find_by(artist_id: artist.id)
    return existing_features if existing_features.present?
    
    # Get artist data from Deezer
    artist_data = get_artist_data(artist.name)
    
    # Log if we got empty features
    if artist_data.empty?
      Rails.logger.warn("Failed to get features for artist: #{artist.name}")
    end
    
    # Save features to database
    save_artist_features(artist, artist_data)
  end
  
  # Process an album and save its features
  def self.process_album(album)
    return nil unless album.is_a?(Album) && album.persisted?
    
    # Check if features already exist
    existing_features = AlbumFeature.find_by(album_id: album.id)
    return existing_features if existing_features.present?
    
    # Get album data from Deezer
    album_data = get_album_data(album.title, album.artist)
    
    # Log if we got empty features
    if album_data.empty?
      Rails.logger.warn("Failed to get features for album: #{album.title} by #{album.artist}")
    end
    
    # Save features to database
    save_album_features(album, album_data)
  end
  
  # Analyze a list of tracks
  def self.analyze_tracks(tracks)
    # Cache key based on track IDs
    track_ids = tracks.map { |t| t[:id] || t['id'] }.compact.join('-')
    cache_key = "music_analysis:#{track_ids}"
    
    # Try to get from cache first
    cached_analysis = Rails.cache.read(cache_key)
    return cached_analysis if cached_analysis.present?
    
    # Extract track and artist info for Deezer
    track_info = prepare_track_data(tracks)
    
    # Analyze each track using Deezer
    tracks_with_features = []
    
    track_info.each do |track|
      track_features = get_track_data(track[:name], track[:artist_name])
      
      tracks_with_features << {
        id: track[:id],
        name: track[:name],
        features: track_features
      }
    end
    
    # Calculate overall features
    overall_features = calculate_overall_features(tracks_with_features.map { |t| t[:features] })
    
    result = {
      tracks: tracks_with_features,
      overall_features: overall_features
    }
    
    # Cache the result
    Rails.cache.write(cache_key, result, expires_in: 1.day)
    result
  end
  
  # Get audio features for a specific track
  def self.get_track_features(track)
    # Try to get from cache first
    track_id = track[:id] || track['id']
    return {} unless track_id
    
    cache_key = "track_features:#{track_id}"
    cached_features = Rails.cache.read(cache_key)
    return cached_features if cached_features.present?
    
    # Extract track and artist name
    track_name = track[:name] || track['name']
    artist_name = extract_artist_name(track)
    
    # Get track info from Deezer
    track_features = get_track_data(track_name, artist_name)
    
    # Cache the result
    Rails.cache.write(cache_key, track_features, expires_in: 7.days)
    track_features
  end
  
  # Calculate average features for a collection of tracks
  def self.calculate_average_features(tracks)
    # If no tracks, return empty features
    return default_features if tracks.blank?
    
    # Get analysis for all tracks
    analysis = analyze_tracks(tracks)
    
    # Return overall features if available
    return analysis[:overall_features] if analysis[:overall_features].present?
    
    # Otherwise calculate average from individual tracks
    track_features = analysis[:tracks]&.map { |t| t[:features] }&.compact || []
    return default_features if track_features.empty?
    
    calculate_overall_features(track_features)
  end
  
  # Get track data from Deezer API
  def self.get_track_data(track_name, artist_name)
    return default_features if track_name.blank? || artist_name.blank?
    
    # Clean up the track and artist names
    track_name = clean_search_term(track_name)
    artist_name = clean_search_term(artist_name)
    
    cache_key = "deezer:track:#{track_name}:#{artist_name}"
    cached_info = Rails.cache.read(cache_key)
    return cached_info if cached_info.present?
    
    begin
      # Try exact match first
      features = search_track_exact(track_name, artist_name)
      
      # If exact match fails, try looser search
      if features == default_features
        features = search_track_loose(track_name, artist_name)
      end
      
      # Cache even default features to avoid repeated failed API calls
      Rails.cache.write(cache_key, features, expires_in: features == default_features ? 1.hour : 7.days)
      features
      
    rescue => e
      Rails.logger.error("Error calling Deezer API: #{e.message}")
      default_features
    end
  end
  
  # Get artist data from Deezer API
  def self.get_artist_data(artist_name)
    return {} if artist_name.blank?
    
    # Clean up the artist name
    artist_name = clean_search_term(artist_name)
    
    cache_key = "deezer:artist:#{artist_name}"
    cached_info = Rails.cache.read(cache_key)
    return cached_info if cached_info.present?
    
    begin
      # Search for the artist on Deezer
      response = Faraday.get("#{API_ROOT}/search/artist") do |req|
        req.params = { q: artist_name }
      end
      
      if response.status == 200
        data = JSON.parse(response.body)
        
        if data['data'] && data['data'].any?
          # Find the best match
          artist_data = data['data'].first
          
          # Get detailed artist info
          if artist_data['id']
            detailed_data = get_detailed_artist_data(artist_data['id'])
            
            # Cache the result
            Rails.cache.write(cache_key, detailed_data, expires_in: 30.days)
            return detailed_data
          end
        end
      end
      
      # If we get here, something went wrong
      Rails.logger.error("Deezer API error for artist '#{artist_name}': #{response.status} - #{response.body}")
      {}
    rescue => e
      Rails.logger.error("Error calling Deezer API: #{e.message}")
      {}
    end
  end
  
  # Get album data from Deezer API
  def self.get_album_data(album_title, artist_name)
    return {} if album_title.blank?
    
    # Clean up the album title and artist name
    album_title = clean_search_term(album_title)
    artist_name = clean_search_term(artist_name) if artist_name.present?
    
    cache_key = "deezer:album:#{album_title}:#{artist_name}"
    cached_info = Rails.cache.read(cache_key)
    return cached_info if cached_info.present?
    
    begin
      # Search for the album on Deezer
      query = artist_name.present? ? "#{album_title} #{artist_name}" : album_title
      response = Faraday.get("#{API_ROOT}/search/album") do |req|
        req.params = { q: query }
      end
      
      if response.status == 200
        data = JSON.parse(response.body)
        
        if data['data'] && data['data'].any?
          # Find the best match
          album_data = data['data'].first
          
          # Get detailed album info
          if album_data['id']
            detailed_data = get_detailed_album_data(album_data['id'])
            
            # Cache the result
            Rails.cache.write(cache_key, detailed_data, expires_in: 30.days)
            return detailed_data
          end
        end
      end
      
      # If we get here, something went wrong
      Rails.logger.error("Deezer API error for album '#{album_title}' by '#{artist_name}': #{response.status} - #{response.body}")
      {}
    rescue => e
      Rails.logger.error("Error calling Deezer API: #{e.message}")
      {}
    end
  end
  
  private
  
  # Clean search terms
  def self.clean_search_term(term)
    return '' if term.blank?
    
    # Remove common problematic characters and extra whitespace
    term.to_s
      .gsub(/\s+/, ' ')           # Replace multiple spaces with single space
      .gsub(/[^\w\s\-']/, '')     # Keep only word chars, spaces, hyphens, apostrophes
      .strip
      .downcase
  end
  
  # Try exact search with both track and artist
  def self.search_track_exact(track_name, artist_name)
    query = "track:\"#{track_name}\" artist:\"#{artist_name}\""
    search_and_extract_features(query, track_name, artist_name)
  end
  
  # Try looser search
  def self.search_track_loose(track_name, artist_name)
    # Try without quotes first
    query = "#{track_name} #{artist_name}"
    features = search_and_extract_features(query, track_name, artist_name)
    
    # If still no luck, try just the track name
    if features == default_features && track_name.present?
      query = track_name
      features = search_and_extract_features(query, track_name, artist_name)
    end
    
    features
  end
  
  # Search and extract features
  def self.search_and_extract_features(query, track_name, artist_name)
    response = Faraday.get("#{API_ROOT}/search") do |req|
      req.params = { 
        q: query,
        limit: 25  # Get more results to find better matches
      }
    end
    
    if response.status == 200
      data = JSON.parse(response.body)
      
      if data['data'] && data['data'].any?
        # Find the best match
        track_data = find_best_match(data['data'], track_name, artist_name)
        
        if track_data
          # Extract basic features
          features = extract_basic_features(track_data)
          
          # Get additional track data if available
          if track_data['id']
            detailed_data = get_detailed_track_data(track_data['id'])
            features = merge_detailed_features(features, detailed_data) if detailed_data
          end
          
          return features
        end
      end
    else
      Rails.logger.error("Deezer API error: #{response.status} - #{response.body}")
    end
    
    default_features
  end
  
  # Extract basic features from search result
  def self.extract_basic_features(track_data)
    features = default_features.dup
    
    # Basic info available in search results
    features[:duration_ms] = track_data['duration'] * 1000 if track_data['duration']
    features[:preview_url] = track_data['preview'] if track_data['preview']
    features[:explicit] = track_data['explicit_lyrics'] if track_data.key?('explicit_lyrics')
    features[:rank] = track_data['rank'] if track_data['rank']
    
    # Calculate popularity from rank
    if track_data['rank']
      features[:popularity] = calculate_popularity_from_rank(track_data['rank'])
    end
    
    features
  end
  
  # Merge detailed features
  def self.merge_detailed_features(features, detailed_data)
    features = features.dup
    
    # Merge in detailed data
    features[:bpm] = detailed_data[:bpm] if detailed_data[:bpm] && detailed_data[:bpm] > 0
    features[:release_date] = detailed_data[:release_date] if detailed_data[:release_date]
    
    # Get album info for genre
    if detailed_data[:album] && detailed_data[:album][:id]
      album_data = get_album_genres(detailed_data[:album][:id])
      if album_data && album_data[:genres].present?
        features[:genre] = album_data[:genres].first
        features[:tags] = album_data[:genres]
      end
    end
    
    # Estimate features based on available data
    features = estimate_audio_features(features)
    
    features
  end
  
  # Get album genres (simplified version)
  def self.get_album_genres(album_id)
    cache_key = "deezer:album:genres:#{album_id}"
    cached = Rails.cache.read(cache_key)
    return cached if cached
    
    begin
      response = Faraday.get("#{API_ROOT}/album/#{album_id}")
      
      if response.status == 200
        data = JSON.parse(response.body)
        
        genres = []
        if data['genres'] && data['genres']['data']
          genres = data['genres']['data'].map { |g| g['name'] }
        elsif data['genre_id']
          # Fallback to genre_id if genres not available
          genre_name = get_genre_name(data['genre_id'])
          genres = [genre_name] if genre_name
        end
        
        result = { genres: genres }
        Rails.cache.write(cache_key, result, expires_in: 30.days)
        result
      end
    rescue => e
      Rails.logger.error("Error getting album genres: #{e.message}")
    end
    
    { genres: [] }
  end
  
  # Get genre name from ID
  def self.get_genre_name(genre_id)
    # Common Deezer genre IDs
    genre_map = {
      0 => "All",
      132 => "Pop",
      116 => "Rap/Hip Hop",
      113 => "Dance",
      165 => "R&B",
      152 => "Rock",
      129 => "Jazz",
      98 => "Classical",
      173 => "Films/Games",
      464 => "Metal",
      169 => "Soul & Funk",
      2 => "African Music",
      12 => "Arabic Music",
      16 => "Asian Music",
      153 => "Blues",
      75 => "Brazilian Music",
      81 => "Indian Music",
      95 => "Kids",
      197 => "Latin Music"
    }
    
    genre_map[genre_id]
  end
  
  # Estimate audio features based on available data
  def self.estimate_audio_features(features)
    features = features.dup
    
    # Estimate energy based on BPM
    if features[:bpm] && features[:bpm] > 0
      features[:energy] = case features[:bpm]
                         when 0..80 then 0.3
                         when 81..100 then 0.5
                         when 101..120 then 0.6
                         when 121..140 then 0.8
                         else 0.9
                         end
      
      # Estimate danceability based on BPM
      features[:danceability] = case features[:bpm]
                               when 90..130 then 0.8
                               when 80..89, 131..140 then 0.6
                               else 0.4
                               end
    end
    
    # Estimate mood based on genre
    if features[:genre]
      features[:mood] = estimate_mood_from_genre(features[:genre])
      features[:acousticness] = estimate_acousticness_from_genre(features[:genre])
    end
    
    # Adjust mood if explicit
    if features[:explicit] == true
      features[:mood] = [features[:mood] - 0.1, 0.1].max
    end
    
    features
  end
  
  # Estimate mood from genre
  def self.estimate_mood_from_genre(genre)
    genre_lower = genre.to_s.downcase
    
    case genre_lower
    when /classical|jazz|blues/
      0.5
    when /metal|rap|hip hop/
      0.4
    when /pop|dance|electronic/
      0.7
    when /soul|r&b|funk/
      0.6
    else
      0.5
    end
  end
  
  # Estimate acousticness from genre
  def self.estimate_acousticness_from_genre(genre)
    genre_lower = genre.to_s.downcase
    
    case genre_lower
    when /classical|jazz|blues|folk|country/
      0.8
    when /acoustic/
      0.9
    when /electronic|dance|techno|house/
      0.1
    when /rock|metal/
      0.3
    else
      0.5
    end
  end
  
  # Calculate popularity from rank
  def self.calculate_popularity_from_rank(rank)
    return 0.5 unless rank && rank > 0
    
    # Deezer rank: lower is better
    # Convert to 0-1 scale where 1 is most popular
    case rank
    when 1..1000
      0.9
    when 1001..10000
      0.8
    when 10001..50000
      0.7
    when 50001..100000
      0.6
    when 100001..500000
      0.5
    when 500001..1000000
      0.4
    else
      0.3
    end
  end
  
  # Get detailed track data
  def self.get_detailed_track_data(track_id)
    cache_key = "deezer:track:details:#{track_id}"
    cached = Rails.cache.read(cache_key)
    return cached if cached
    
    begin
      response = Faraday.get("#{API_ROOT}/track/#{track_id}")
      
      if response.status == 200
        data = JSON.parse(response.body)
        
        result = {
          id: data['id'],
          title: data['title'],
          duration_ms: data['duration'] * 1000,
          release_date: data['release_date'],
          bpm: data['bpm'].to_i,
          explicit_lyrics: data['explicit_lyrics'],
          preview_url: data['preview'],
          rank: data['rank'],
          album: {
            id: data['album']['id'],
            title: data['album']['title'],
            cover: data['album']['cover_xl']
          },
          artist: {
            id: data['artist']['id'],
            name: data['artist']['name']
          }
        }
        
        Rails.cache.write(cache_key, result, expires_in: 7.days)
        result
      end
    rescue => e
      Rails.logger.error("Error getting detailed track data: #{e.message}")
    end
    
    nil
  end
  
  # Find the best match from search results
  def self.find_best_match(results, track_name, artist_name)
    # Normalize names for comparison
    track_normalized = normalize_for_matching(track_name)
    artist_normalized = normalize_for_matching(artist_name)
    
    # Score each result
    scored_results = results.map do |result|
      score = calculate_match_score(
        result,
        track_normalized,
        artist_normalized
      )
      { result: result, score: score }
    end
    
    # Sort by score and get best match
    best_match = scored_results.max_by { |r| r[:score] }
    
    # Only return if score is above threshold
    best_match && best_match[:score] > 0.3 ? best_match[:result] : nil
  end
  
  # Calculate match score
  def self.calculate_match_score(result, target_track, target_artist)
    track_score = string_similarity(
      normalize_for_matching(result['title']),
      target_track
    )
    
    artist_score = string_similarity(
      normalize_for_matching(result['artist']['name']),
      target_artist
    )
    
    # Weight artist match slightly higher
    (track_score * 0.4) + (artist_score * 0.6)
  end
  
  # Normalize string for matching
  def self.normalize_for_matching(str)
    return '' unless str
    
    str.to_s
      .downcase
      .gsub(/[^\w\s]/, '')  # Remove punctuation
      .gsub(/\s+/, ' ')     # Normalize spaces
      .strip
  end
  
  # Simple string similarity
  def self.string_similarity(str1, str2)
    return 0.0 if str1.blank? || str2.blank?
    return 1.0 if str1 == str2
    
    # Simple token-based similarity
    tokens1 = str1.split.to_set
    tokens2 = str2.split.to_set
    
    return 0.0 if tokens1.empty? || tokens2.empty?
    
    intersection = tokens1 & tokens2
    union = tokens1 | tokens2
    
    intersection.size.to_f / union.size
  end
  
  # Save track features to database
  def self.save_track_features(track, features)
    track_feature = TrackFeature.find_or_initialize_by(track_id: track.id)
    
    # Update attributes based on features from Deezer
    track_feature.assign_attributes(
      genre: features[:genre],
      bpm: features[:bpm],
      mood: mood_to_string(features[:mood]),
      character: character_from_features(features),
      movement: movement_from_bpm(features[:bpm]),
      vocals: has_vocals_from_features(features),
      emotion: emotion_from_mood(features[:mood]),
      emotional_dynamics: emotional_dynamics_from_features(features),
      instruments: instruments_from_features(features).join(", "),
      length: features[:duration_ms] ? features[:duration_ms] / 1000.0 : nil,
      popularity: (features[:popularity] * 100).to_i # Convert to percentage
    )
    
    track_feature.save!
    track_feature
  rescue => e
    Rails.logger.error("Failed to save track features: #{e.message}")
    nil
  end
  
  # Save artist features to database
  def self.save_artist_features(artist, features)
    artist_feature = ArtistFeature.find_or_initialize_by(artist_id: artist.id)
    
    # Update attributes based on features from Deezer
    artist_feature.assign_attributes(
      genre: features[:genres]&.first,
      era: era_from_artist(features),
      instruments: instruments_from_features(features)&.first(3)&.join(", "),
      mood: mood_to_string(features[:mood]),
      themes: themes_from_genres(features[:genres]),
      energy_level: energy_level_from_features(features),
      popularity: features[:nb_fan] || 0
    )
    
    artist_feature.save!
    artist_feature
  rescue => e
    Rails.logger.error("Failed to save artist features: #{e.message}")
    nil
  end
  
  # Save album features to database
  def self.save_album_features(album, features)
    album_feature = AlbumFeature.find_or_initialize_by(album_id: album.id)
    
    # Update attributes based on features from Deezer
    album_feature.assign_attributes(
      genre: features[:genres]&.first,
      era: era_from_release_date(features[:release_date]),
      instruments: instruments_from_features(features)&.first(3)&.join(", "),
      mood: mood_to_string(features[:mood]),
      themes: themes_from_genres(features[:genres]),
      num_tracks: features[:nb_tracks],
      length: features[:duration] ? features[:duration] / 60.0 : nil, # Convert to minutes
      popularity: features[:fans] || 0
    )
    
    album_feature.save!
    album_feature
  rescue => e
    Rails.logger.error("Failed to save album features: #{e.message}")
    nil
  end
  
  # Default features to use when API fails
  def self.default_features
    {
      energy: 0.5,
      mood: 0.5,
      danceability: 0.5,
      acousticness: 0.5,
      popularity: 0.5,
      bpm: nil,
      duration_ms: nil,
      tags: [],
      genre: nil,
      explicit: false
    }
  end
  
  # ... (include all the helper methods from the original: mood_to_string, character_from_features, etc.)
  
  # Convert mood float to string
  def self.mood_to_string(mood_value)
    return "neutral" unless mood_value
    
    case mood_value
    when 0.0..0.3
      "melancholic"
    when 0.3..0.5
      "neutral"
    when 0.5..0.7
      "upbeat"
    when 0.7..1.0
      "euphoric"
    else
      "neutral"
    end
  end
  
  # Determine character from features
  def self.character_from_features(features)
    return "balanced" unless features
    
    if features[:acousticness] && features[:acousticness] > 0.7
      "acoustic"
    elsif features[:energy] && features[:energy] > 0.7
      "energetic"
    elsif features[:danceability] && features[:danceability] > 0.7
      "rhythmic"
    else
      "balanced"
    end
  end
  
  # Determine movement from BPM
  def self.movement_from_bpm(bpm)
    return "moderate" unless bpm && bpm > 0
    
    case bpm
    when 1..70
      "slow"
    when 71..120
      "moderate"
    when 121..180
      "fast"
    else
      "very fast"
    end
  end
  
  # Determine if track has vocals
  def self.has_vocals_from_features(features)
    return true unless features && features[:genre]
    
    instrumental_genres = ["classical", "instrumental", "ambient", "electronic"]
    !instrumental_genres.any? { |g| features[:genre]&.downcase&.include?(g) }
  end
  
  # Determine emotion from mood
  def self.emotion_from_mood(mood_value)
    return "neutral" unless mood_value
    
    case mood_value
    when 0.0..0.3
      "sad"
    when 0.3..0.5
      "contemplative"
    when 0.5..0.7
      "happy"
    when 0.7..1.0
      "joyful"
    else
      "neutral"
    end
  end
  
  # Determine emotional dynamics from features
  def self.emotional_dynamics_from_features(features)
    return "balanced" unless features
    
    energy = features[:energy] || 0.5
    mood = features[:mood] || 0.5
    
    if energy > 0.7 && mood < 0.3
      "intense sadness"
    elsif energy > 0.7 && mood > 0.7
      "euphoric"
    elsif energy < 0.3 && mood < 0.3
      "melancholic"
    elsif energy < 0.3 && mood > 0.7
      "peaceful joy"
    else
      "balanced"
    end
  end
  
  # Extract instruments from features
  def self.instruments_from_features(features)
    return ["vocals"] unless features && features[:genre]
    
    genre = features[:genre].to_s.downcase
    
    instruments = case genre
    when /rock/
      ["guitar", "drums", "bass", "vocals"]
    when /pop/
      ["synthesizer", "drums", "vocals", "piano"]
    when /hip hop|rap/
      ["drums", "synthesizer", "sampler", "vocals"]
    when /electronic|dance|house|techno/
      ["synthesizer", "drum machine", "sampler"]
    when /jazz/
      ["saxophone", "piano", "drums", "bass"]
    when /classical/
      ["violin", "piano", "cello", "flute"]
    when /country|folk/
      ["guitar", "banjo", "fiddle", "vocals"]
    when /r&b|soul/
      ["piano", "drums", "bass", "vocals"]
    when /metal/
      ["guitar", "drums", "bass", "vocals"]
    else
      ["vocals"]
    end
    
    instruments.uniq
  end
end