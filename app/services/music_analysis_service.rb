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
    
    # Save features to database
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
    
    cache_key = "deezer:track:#{track_name}:#{artist_name}"
    cached_info = Rails.cache.read(cache_key)
    return cached_info if cached_info.present?
    
    begin
      # Search for the track on Deezer
      query = "#{track_name} #{artist_name}"
      response = Faraday.get("#{API_ROOT}/search") do |req|
        req.params = { q: query }
      end
      
      if response.status == 200
        data = JSON.parse(response.body)
        
        if data['data'] && data['data'].any?
          # Find the best match
          track_data = find_best_match(data['data'], track_name, artist_name)
          
          if track_data
            # Extract features from the track data
            features = extract_features_from_deezer(track_data)
            
            # Get additional track data if available
            if track_data['id']
              detailed_data = get_detailed_track_data(track_data['id'])
              features.merge!(detailed_data) if detailed_data
            end
            
            # Cache the result
            Rails.cache.write(cache_key, features, expires_in: 7.days)
            return features
          end
        end
      end
      
      # If we get here, something went wrong
      Rails.logger.error("Deezer API error for track '#{track_name}' by '#{artist_name}': #{response.status} - #{response.body}")
      default_features
    rescue => e
      Rails.logger.error("Error calling Deezer API: #{e.message}")
      default_features
    end
  end
  
  # Get artist data from Deezer API
  def self.get_artist_data(artist_name)
    return {} if artist_name.blank?
    
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
  
  # Save track features to database
  def self.save_track_features(track, features)
    # Map Deezer features to our database schema
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
      instruments: instruments_from_features(features),
      length: features[:duration_ms] ? features[:duration_ms] / 1000.0 : nil,
      popularity: features[:rank] || 0 # Add popularity from Deezer rank
    )
    
    track_feature.save
    track_feature
  end
  
  # Save artist features to database
  def self.save_artist_features(artist, features)
    # Map Deezer features to our database schema
    artist_feature = ArtistFeature.find_or_initialize_by(artist_id: artist.id)
    
    # Update attributes based on features from Deezer
    artist_feature.assign_attributes(
      genre: features[:genres]&.first,
      era: era_from_artist(features),
      instruments: instruments_from_features(features)&.first(3)&.join(", "),
      mood: mood_to_string(features[:mood]),
      themes: themes_from_genres(features[:genres]),
      energy_level: energy_level_from_features(features),
      popularity: features[:nb_fan] || 0 # Add popularity from Deezer nb_fan
    )
    
    artist_feature.save
    artist_feature
  end
  
  # Save album features to database
  def self.save_album_features(album, features)
    # Map Deezer features to our database schema
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
      popularity: features[:fans] || 0 # Add popularity from Deezer fans
    )
    
    album_feature.save
    album_feature
  end
  
  # Helper methods for feature mapping
  
  # Convert mood float to string
  def self.mood_to_string(mood_value)
    return nil unless mood_value
    
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
    return nil unless features
    
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
    return nil unless bpm
    
    case bpm
    when 0..70
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
    # This is a guess since Deezer doesn't provide this info directly
    # Would need more data to make a better guess
    return nil unless features && features[:genre]
    
    instrumental_genres = ["classical", "instrumental", "ambient", "electronic"]
    !instrumental_genres.include?(features[:genre]&.downcase)
  end
  
  # Determine emotion from mood
  def self.emotion_from_mood(mood_value)
    return nil unless mood_value
    
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
    return nil unless features
    
    if features[:energy] && features[:energy] > 0.7 && features[:mood] && features[:mood] < 0.3
      "intense sadness"
    elsif features[:energy] && features[:energy] > 0.7 && features[:mood] && features[:mood] > 0.7
      "euphoric"
    elsif features[:energy] && features[:energy] < 0.3 && features[:mood] && features[:mood] < 0.3
      "melancholic"
    elsif features[:energy] && features[:energy] < 0.3 && features[:mood] && features[:mood] > 0.7
      "peaceful joy"
    else
      "balanced"
    end
  end
  
  # Extract instruments from features
  def self.instruments_from_features(features)
    # This is a guess since Deezer doesn't provide this info directly
    return [] unless features && features[:genre]
    
    case features[:genre]&.downcase
    when "rock"
      ["guitar", "drums", "bass"]
    when "pop"
      ["synthesizer", "drums", "vocals"]
    when "hip hop", "rap"
      ["drums", "synthesizer", "sampler"]
    when "electronic", "dance"
      ["synthesizer", "drum machine", "sampler"]
    when "jazz"
      ["saxophone", "piano", "drums", "bass"]
    when "classical"
      ["violin", "piano", "cello", "flute"]
    when "country"
      ["guitar", "banjo", "fiddle"]
    when "r&b", "soul"
      ["piano", "drums", "bass", "horns"]
    else
      ["guitar", "piano", "drums"]
    end
  end
  
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
    return nil unless features && features[:energy]
    
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
  
  # Get detailed track data
  def self.get_detailed_track_data(track_id)
    begin
      response = Faraday.get("#{API_ROOT}/track/#{track_id}")
      
      if response.status == 200
        data = JSON.parse(response.body)
        
        return {
          id: data['id'],
          title: data['title'],
          duration_ms: data['duration'] * 1000, # Deezer provides duration in seconds
          release_date: data['release_date'],
          bpm: data['bpm'],
          explicit_lyrics: data['explicit_lyrics'],
          preview_url: data['preview'],
          rank: data['rank'], # Extract Deezer rank for popularity
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
      end
      
      nil
    rescue => e
      Rails.logger.error("Error getting detailed track data: #{e.message}")
      nil
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
        
        # Get artist's genres
        genres = get_artist_genres(artist_id)
        
        return {
          id: artist_data['id'],
          name: artist_data['name'],
          link: artist_data['link'],
          picture: artist_data['picture_xl'],
          nb_album: artist_data['nb_album'],
          nb_fan: artist_data['nb_fan'], # Extract Deezer nb_fan for popularity
          radio: artist_data['radio'],
          tracklist: artist_data['tracklist'],
          top_tracks: top_tracks,
          genres: genres
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
  
  # Get artist's genres
  def self.get_artist_genres(artist_id)
    begin
      response = Faraday.get("#{API_ROOT}/artist/#{artist_id}/genres")
      
      if response.status == 200
        data = JSON.parse(response.body)
        
        if data['data']
          return data['data'].map { |genre| genre['name'] }
        end
      end
      
      []
    rescue => e
      Rails.logger.error("Error getting artist genres: #{e.message}")
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
          fans: album_data['fans'], # Extract Deezer fans for popularity
          release_date: album_data['release_date'],
          tracks: tracks,
          artist: {
            id: album_data['artist']['id'],
            name: album_data['artist']['name']
          }
        }
      end
      
      {}
    rescue => e
      Rails.logger.error("Error getting detailed album data: #{e.message}")
      {}
    end
  end
  
  # Find the best match from search results
  def self.find_best_match(results, track_name, artist_name)
    # Normalize names for comparison
    track_name_normalized = normalize_string(track_name)
    artist_name_normalized = normalize_string(artist_name)
    
    # First try to find an exact match
    exact_match = results.find do |result|
      normalize_string(result['title']) == track_name_normalized && 
      normalize_string(result['artist']['name']) == artist_name_normalized
    end
    
    return exact_match if exact_match
    
    # If no exact match, try to find a close match
    # First prioritize artist match
    artist_match = results.find do |result|
      normalize_string(result['artist']['name']) == artist_name_normalized
    end
    
    return artist_match if artist_match
    
    # If no artist match, return the first result
    results.first
  end
  
  # Normalize string for comparison
  def self.normalize_string(str)
    return '' unless str
    str.downcase.gsub(/[^\w\s]/, '').strip
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
  
  # Extract features from Deezer track data
  def self.extract_features_from_deezer(track_data)
    features = default_features
    
    # Extract available data
    features[:popularity] = calculate_popularity(track_data['rank']) if track_data['rank']
    
    # Extract genre if available
    if track_data['album'] && track_data['album']['id']
      album_data = get_detailed_album_data(track_data['album']['id'])
      if album_data && album_data[:genres]
        features[:genre] = album_data[:genres].first
        features[:tags] = album_data[:genres]
      end
    end
    
    # Extract BPM if available
    if track_data['bpm'] && track_data['bpm'] > 0
      features[:bpm] = track_data['bpm']
      
      # Estimate energy based on BPM
      # Typically: <80 BPM = low energy, 80-120 = medium, >120 = high
      if track_data['bpm'] < 80
        features[:energy] = 0.3
      elsif track_data['bpm'] < 120
        features[:energy] = 0.6
      else
        features[:energy] = 0.9
      end
      
      # Estimate danceability based on BPM
      # Typically: 90-130 BPM is most danceable
      if track_data['bpm'] >= 90 && track_data['bpm'] <= 130
        features[:danceability] = 0.8
      else
        features[:danceability] = 0.4
      end
    end
    
    # If we have explicit lyrics info, use it to adjust mood
    if track_data['explicit_lyrics']
      features[:mood] = 0.4 # Explicit lyrics often correlate with less positive mood
    end
    
    features
  end
  
  # Calculate popularity score from Deezer rank
  def self.calculate_popularity(rank)
    return 0.5 unless rank && rank > 0
    
    # Deezer rank can go into the millions, so we use a logarithmic scale
    # Higher rank = more popular
    [Math.log10(rank).to_f / 6, 1.0].min
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
  
  # Default features to use when API fails
  def self.default_features
    {
      energy: 0.5,
      mood: 0.5,
      danceability: 0.5,
      acousticness: 0.5,
      popularity: 0.5,
      tags: [],
      genre: nil
    }
  end
end
