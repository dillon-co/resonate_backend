class MusicAnalysisService
  # Last.fm API configuration
  API_KEY = ENV['LASTFM_API_KEY']
  SHARED_SECRET = ENV['LASTFM_SHARED_SECRET']
  API_ROOT = 'https://ws.audioscrobbler.com/2.0/'
  
  # Analyze a list of tracks
  def self.analyze_tracks(tracks)
    # Cache key based on track IDs
    track_ids = tracks.map { |t| t[:id] || t['id'] }.compact.join('-')
    cache_key = "music_analysis:#{track_ids}"
    
    # Try to get from cache first
    cached_analysis = Rails.cache.read(cache_key)
    return cached_analysis if cached_analysis.present?
    
    # Extract track and artist info for Last.fm
    track_info = prepare_track_data(tracks)
    
    # Analyze each track using Last.fm
    tracks_with_features = []
    
    track_info.each do |track|
      track_features = get_track_info_from_lastfm(track[:name], track[:artist_name])
      
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
    
    # Get track info from Last.fm
    track_features = get_track_info_from_lastfm(track_name, artist_name)
    
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
  
  private
  
  # Prepare track data for Last.fm API
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
  
  # Get track info from Last.fm
  def self.get_track_info_from_lastfm(track_name, artist_name)
    return default_features if track_name.blank? || artist_name.blank?
    
    cache_key = "lastfm:track:#{track_name}:#{artist_name}"
    cached_info = Rails.cache.read(cache_key)
    return cached_info if cached_info.present?
    
    begin
      # Make Last.fm API call
      response = Faraday.get(API_ROOT) do |req|
        req.params = {
          method: 'track.getInfo',
          api_key: API_KEY,
          artist: artist_name,
          track: track_name,
          format: 'json'
        }
      end
      
      if response.status == 200
        data = JSON.parse(response.body)
        
        if data['track']
          # Extract relevant info
          features = extract_features_from_lastfm(data['track'])
          
          # Get tags for the track
          tags = extract_tags_from_lastfm(data['track'])
          
          # Add tags to features
          features[:tags] = tags
          
          # Get genre from tags
          features[:genre] = determine_genre_from_tags(tags)
          
          # Cache the result
          Rails.cache.write(cache_key, features, expires_in: 7.days)
          return features
        end
      end
      
      # If we get here, something went wrong
      Rails.logger.error("Last.fm API error for track '#{track_name}' by '#{artist_name}': #{response.status} - #{response.body}")
      default_features
    rescue => e
      Rails.logger.error("Error calling Last.fm API: #{e.message}")
      default_features
    end
  end
  
  # Extract features from Last.fm track data
  def self.extract_features_from_lastfm(track_data)
    features = default_features
    
    # Extract available data
    features[:listeners] = track_data['listeners'].to_i if track_data['listeners']
    features[:playcount] = track_data['playcount'].to_i if track_data['playcount']
    
    # Calculate popularity score (0-1)
    if features[:listeners] > 0
      # Logarithmic scale for popularity (1000 listeners = 0.5, 1M listeners = 1.0)
      features[:popularity] = [Math.log10(features[:listeners]).to_f / 6, 1.0].min
    end
    
    # If duration is available, categorize tempo
    if track_data['duration']
      duration_ms = track_data['duration'].to_i
      features[:duration_ms] = duration_ms
    end
    
    features
  end
  
  # Extract tags from Last.fm track data
  def self.extract_tags_from_lastfm(track_data)
    return [] unless track_data['toptags'] && track_data['toptags']['tag']
    
    tags = track_data['toptags']['tag']
    tags = [tags] unless tags.is_a?(Array)
    
    tags.map { |tag| tag['name'].downcase }
  end
  
  # Determine genre from tags
  def self.determine_genre_from_tags(tags)
    return nil if tags.empty?
    
    # Common genre tags
    genre_map = {
      'rock' => ['rock', 'alternative rock', 'indie rock', 'hard rock', 'classic rock'],
      'pop' => ['pop', 'indie pop', 'synth pop', 'electropop'],
      'electronic' => ['electronic', 'edm', 'house', 'techno', 'trance', 'dubstep'],
      'hip hop' => ['hip hop', 'rap', 'trap', 'grime'],
      'r&b' => ['r&b', 'rnb', 'soul', 'funk'],
      'jazz' => ['jazz', 'swing', 'bebop', 'fusion'],
      'metal' => ['metal', 'heavy metal', 'death metal', 'black metal', 'thrash'],
      'country' => ['country', 'americana', 'bluegrass'],
      'folk' => ['folk', 'acoustic', 'singer-songwriter'],
      'classical' => ['classical', 'orchestra', 'baroque', 'piano'],
      'reggae' => ['reggae', 'ska', 'dub'],
      'blues' => ['blues'],
      'punk' => ['punk', 'punk rock', 'hardcore'],
      'indie' => ['indie', 'alternative', 'lo-fi']
    }
    
    # Check if any tags match our genre map
    genre_map.each do |genre, related_tags|
      return genre if tags.any? { |tag| related_tags.include?(tag) }
    end
    
    # If no match found, return the first tag as genre
    tags.first
  end
  
  # Calculate energy, danceability, etc. from tags
  def self.calculate_mood_features_from_tags(tags)
    features = {}
    
    # Energy tags
    energy_tags = {
      high: ['energetic', 'powerful', 'intense', 'fast', 'upbeat', 'epic'],
      medium: ['moderate', 'groovy', 'rhythmic'],
      low: ['calm', 'chill', 'relaxing', 'slow', 'mellow', 'ambient', 'soft']
    }
    
    # Mood tags
    mood_tags = {
      positive: ['happy', 'uplifting', 'feel good', 'cheerful', 'euphoric', 'joyful'],
      neutral: ['atmospheric', 'dreamy', 'introspective'],
      negative: ['sad', 'melancholic', 'dark', 'angry', 'gloomy', 'depressing']
    }
    
    # Danceability tags
    dance_tags = {
      high: ['dance', 'danceable', 'club', 'party', 'groovy', 'funky'],
      medium: ['rhythmic', 'beat', 'catchy'],
      low: ['ambient', 'atmospheric', 'experimental', 'drone']
    }
    
    # Calculate energy score
    energy_score = calculate_tag_score(tags, energy_tags)
    features[:energy] = energy_score
    
    # Calculate mood score (0 = negative, 1 = positive)
    mood_score = calculate_tag_score(tags, mood_tags, [:negative, :neutral, :positive])
    features[:mood] = mood_score
    
    # Calculate danceability
    dance_score = calculate_tag_score(tags, dance_tags)
    features[:danceability] = dance_score
    
    # Calculate acousticness (inverse of electronic)
    electronic_tags = ['electronic', 'edm', 'synth', 'techno', 'house', 'electro']
    acoustic_tags = ['acoustic', 'unplugged', 'live', 'organic']
    
    electronic_count = tags.count { |tag| electronic_tags.include?(tag) }
    acoustic_count = tags.count { |tag| acoustic_tags.include?(tag) }
    
    if electronic_count > 0 || acoustic_count > 0
      features[:acousticness] = acoustic_count.to_f / (electronic_count + acoustic_count)
    else
      features[:acousticness] = 0.5
    end
    
    features
  end
  
  # Calculate a score based on tags
  def self.calculate_tag_score(tags, tag_map, order = [:low, :medium, :high])
    counts = order.map { |level| tags.count { |tag| tag_map[level].include?(tag) } }
    total = counts.sum
    
    return 0.5 if total == 0
    
    # Calculate weighted average
    weighted_sum = 0
    order.each_with_index do |_, i|
      weighted_sum += counts[i] * (i.to_f / (order.size - 1))
    end
    
    weighted_sum / total
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
    
    # Add mood features from tags
    if top_tags.any?
      mood_features = calculate_mood_features_from_tags(top_tags)
      overall.merge!(mood_features)
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
