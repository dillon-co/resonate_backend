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
    end
    
    # Save features to database (even if default)
    save_track_features(track, track_data)
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