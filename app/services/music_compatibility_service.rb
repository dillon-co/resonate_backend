class MusicCompatibilityService
  # Calculate musical compatibility between two users
  def self.calculate_compatibility(user1, user2, options = {})
    # Options: depth, use_cache, include_breakdown
    depth = options[:depth] || :overall
    use_cache = options.fetch(:use_cache, true)
    include_breakdown = options[:include_breakdown] || false
    
    # Check if both users have embeddings
    if user1.embedding.present? && user2.embedding.present?
      score = calculate_embedding_compatibility(user1, user2, use_cache: use_cache)
      
      if include_breakdown
        breakdown = calculate_compatibility_breakdown(user1, user2)
        return { score: score, breakdown: breakdown }
      else
        return score
      end
    end
    
    # Fallback to feature-based compatibility if no embeddings
    calculate_feature_based_compatibility(user1, user2, depth: depth, include_breakdown: include_breakdown)
  end
  
  # Calculate compatibility using user embeddings based on Cosine Similarity
  def self.calculate_embedding_compatibility(user1, user2, use_cache: true)
    # Ensure both users have embeddings
    unless user1.embedding.present? && user2.embedding.present?
      # Try to generate embeddings if not present
      UserEmbeddingService.update_embedding_for(user1) unless user1.embedding.present?
      UserEmbeddingService.update_embedding_for(user2) unless user2.embedding.present?
      
      # Reload users to get updated embeddings
      user1.reload
      user2.reload
      
      # If still no embeddings, return a default low score
      unless user1.embedding.present? && user2.embedding.present?
        Rails.logger.warn("Could not generate embeddings for compatibility check between users #{user1.id} and #{user2.id}")
        return 0
      end
    end
    
    if use_cache
      # Cache key for the compatibility score
      cache_key = compatibility_cache_key(user1, user2)
      
      # Try to get from cache first
      cached_score = Rails.cache.read(cache_key)
      return cached_score if cached_score.present?
    end
    
    # Parse embeddings (handle different formats)
    embedding1 = parse_embedding(user1.embedding)
    embedding2 = parse_embedding(user2.embedding)
    
    # Calculate Cosine Similarity
    similarity = cosine_similarity(embedding1, embedding2)
    
    # Convert similarity score from [-1, 1] range to [0, 100] scale
    score = normalize_similarity_score(similarity)
    
    # Cache the result if caching is enabled
    if use_cache
      Rails.cache.write(cache_key, score, expires_in: 1.day)
    end
    
    score
  end
  
  # Calculate feature-based compatibility (fallback when no embeddings)
  def self.calculate_feature_based_compatibility(user1, user2, depth: :overall, include_breakdown: false)
    scores = {}
    
    # Compare shared tracks
    track_score = calculate_track_overlap_score(user1, user2)
    scores[:tracks] = track_score
    
    # Compare shared artists
    artist_score = calculate_artist_overlap_score(user1, user2)
    scores[:artists] = artist_score
    
    # Compare shared albums
    album_score = calculate_album_overlap_score(user1, user2)
    scores[:albums] = album_score
    
    # Compare music features (genres, moods, etc.)
    feature_score = calculate_feature_similarity_score(user1, user2)
    scores[:features] = feature_score
    
    # Check anthem compatibility
    anthem_score = calculate_anthem_compatibility(user1, user2)
    scores[:anthem] = anthem_score
    
    # Calculate weighted overall score
    overall_score = calculate_weighted_score(scores, depth)
    
    if include_breakdown
      { score: overall_score, breakdown: scores }
    else
      overall_score
    end
  end
  
  # Calculate compatibility breakdown for detailed insights
  def self.calculate_compatibility_breakdown(user1, user2)
    breakdown = {}
    
    # Shared content analysis
    breakdown[:shared_tracks] = shared_tracks_analysis(user1, user2)
    breakdown[:shared_artists] = shared_artists_analysis(user1, user2)
    breakdown[:shared_albums] = shared_albums_analysis(user1, user2)
    
    # Feature analysis
    breakdown[:genre_compatibility] = genre_compatibility_analysis(user1, user2)
    breakdown[:mood_compatibility] = mood_compatibility_analysis(user1, user2)
    
    # Anthem analysis
    if user1.anthem_track_id || user2.anthem_track_id
      breakdown[:anthem_compatibility] = anthem_compatibility_analysis(user1, user2)
    end
    
    breakdown
  end
  
  # Find most compatible users for a given user
  def self.find_compatible_users(user, limit: 10, min_score: 50)
    return [] unless user.embedding.present?
    
    # Get all other users with embeddings
    candidates = User.where.not(id: user.id)
                     .where.not(embedding: nil)
                     .select(:id, :display_name, :profile_photo_url, :embedding)
    
    # Calculate compatibility scores
    compatible_users = []
    
    candidates.find_each do |candidate|
      score = calculate_embedding_compatibility(user, candidate, use_cache: true)
      
      if score >= min_score
        compatible_users << {
          user: candidate,
          score: score,
          compatibility_level: compatibility_level(score)
        }
      end
    end
    
    # Sort by score and return top N
    compatible_users.sort_by { |item| -item[:score] }
                    .first(limit)
  end
  
  # Get compatibility insights between two users
  def self.get_compatibility_insights(user1, user2)
    insights = []
    
    # Get basic compatibility score
    score = calculate_compatibility(user1, user2, include_breakdown: true)
    overall_score = score[:score]
    breakdown = score[:breakdown]
    
    # Generate insights based on score and breakdown
    if overall_score >= 90
      insights << "You two are musical soulmates! 🎵"
    elsif overall_score >= 75
      insights << "You have excellent musical compatibility!"
    elsif overall_score >= 60
      insights << "You share quite a bit of musical taste."
    elsif overall_score >= 40
      insights << "You have some musical common ground."
    else
      insights << "Your musical tastes are quite different - could be interesting!"
    end
    
    # Specific insights from breakdown
    if breakdown[:shared_artists][:count] > 5
      insights << "You both love #{breakdown[:shared_artists][:top_shared].first(3).join(', ')}!"
    end
    
    if breakdown[:genre_compatibility][:top_shared_genres].any?
      insights << "You both enjoy #{breakdown[:genre_compatibility][:top_shared_genres].first(2).join(' and ')} music."
    end
    
    if breakdown[:anthem_compatibility] && breakdown[:anthem_compatibility][:same_anthem]
      insights << "You have the same anthem track! That's rare! 🎶"
    end
    
    {
      score: overall_score,
      level: compatibility_level(overall_score),
      insights: insights,
      breakdown: breakdown
    }
  end
  
  private
  
  # Parse embedding from various formats
  def self.parse_embedding(embedding)
    case embedding
    when Array
      embedding
    when String
      JSON.parse(embedding)
    else
      embedding.to_a
    end
  rescue => e
    Rails.logger.error("Error parsing embedding: #{e.message}")
    []
  end
  
  # Generate cache key for compatibility
  def self.compatibility_cache_key(user1, user2)
    user_ids = [user1.id, user2.id].sort
    timestamps = [user1.updated_at.to_i, user2.updated_at.to_i]
    "music_compatibility:v2:#{user_ids.join('-')}:#{timestamps.join('-')}"
  end
  
  # Normalize similarity score to 0-100 range
  def self.normalize_similarity_score(similarity)
    # Convert from [-1, 1] to [0, 100]
    # Apply slight exponential curve to make differences more pronounced
    normalized = (similarity + 1.0) / 2.0  # [0, 1]
    curved = normalized ** 1.5  # Apply slight curve
    (curved * 100).round(1)
  end
  
  # Calculate track overlap score
  def self.calculate_track_overlap_score(user1, user2)
    user1_tracks = user1.tracks.pluck(:id).to_set
    user2_tracks = user2.tracks.pluck(:id).to_set
    
    return 0 if user1_tracks.empty? || user2_tracks.empty?
    
    common = user1_tracks & user2_tracks
    total = user1_tracks | user2_tracks
    
    # Jaccard similarity
    (common.size.to_f / total.size * 100).round(1)
  end
  
  # Calculate artist overlap score
  def self.calculate_artist_overlap_score(user1, user2)
    user1_artists = user1.artists.pluck(:id).to_set
    user2_artists = user2.artists.pluck(:id).to_set
    
    return 0 if user1_artists.empty? || user2_artists.empty?
    
    common = user1_artists & user2_artists
    total = user1_artists | user2_artists
    
    (common.size.to_f / total.size * 100).round(1)
  end
  
  # Calculate album overlap score
  def self.calculate_album_overlap_score(user1, user2)
    user1_albums = user1.albums.pluck(:id).to_set
    user2_albums = user2.albums.pluck(:id).to_set
    
    return 0 if user1_albums.empty? || user2_albums.empty?
    
    common = user1_albums & user2_albums
    total = user1_albums | user2_albums
    
    (common.size.to_f / total.size * 100).round(1)
  end
  
  # Calculate feature similarity score
  def self.calculate_feature_similarity_score(user1, user2)
    # Get top genres for each user
    user1_genres = get_user_top_genres(user1)
    user2_genres = get_user_top_genres(user2)
    
    return 0 if user1_genres.empty? || user2_genres.empty?
    
    # Calculate genre overlap
    common_genres = user1_genres & user2_genres
    total_genres = user1_genres | user2_genres
    
    (common_genres.size.to_f / total_genres.size * 100).round(1)
  end
  
  # Calculate anthem compatibility
  def self.calculate_anthem_compatibility(user1, user2)
    return 0 unless user1.anthem_track_id && user2.anthem_track_id
    
    # Same anthem = perfect score
    return 100 if user1.anthem_track_id == user2.anthem_track_id
    
    # Otherwise, compare anthem features
    anthem1_features = TrackFeature.find_by(track_id: user1.anthem_track_id)
    anthem2_features = TrackFeature.find_by(track_id: user2.anthem_track_id)
    
    return 0 unless anthem1_features && anthem2_features
    
    # Compare anthem embeddings if available
    if anthem1_features.embedding.present? && anthem2_features.embedding.present?
      similarity = cosine_similarity(
        parse_embedding(anthem1_features.embedding),
        parse_embedding(anthem2_features.embedding)
      )
      normalize_similarity_score(similarity)
    else
      # Fallback to feature comparison
      compare_track_features_similarity(anthem1_features, anthem2_features)
    end
  end
  
  # Get user's top genres
  def self.get_user_top_genres(user, limit: 5)
    # Get genres from user's tracks
    track_genres = TrackFeature
      .joins(track: :user_tracks)
      .where(user_tracks: { user_id: user.id })
      .where.not(genre: nil)
      .group(:genre)
      .order('COUNT(*) DESC')
      .limit(limit)
      .pluck(:genre)
    
    track_genres.to_set
  end
  
  # Calculate weighted overall score
  def self.calculate_weighted_score(scores, depth)
    weights = case depth
              when :shallow
                { tracks: 0.3, artists: 0.3, albums: 0.2, features: 0.15, anthem: 0.05 }
              when :medium
                { tracks: 0.25, artists: 0.25, albums: 0.2, features: 0.2, anthem: 0.1 }
              when :deep, :overall
                { tracks: 0.2, artists: 0.25, albums: 0.15, features: 0.25, anthem: 0.15 }
              else
                { tracks: 0.2, artists: 0.2, albums: 0.2, features: 0.2, anthem: 0.2 }
              end
    
    total_score = 0
    total_weight = 0
    
    scores.each do |key, score|
      if weights[key] && score
        total_score += score * weights[key]
        total_weight += weights[key]
      end
    end
    
    total_weight > 0 ? (total_score / total_weight).round(1) : 0
  end
  
  # Shared tracks analysis
  def self.shared_tracks_analysis(user1, user2)
    shared_track_ids = user1.tracks.pluck(:id) & user2.tracks.pluck(:id)
    
    shared_tracks = Track.where(id: shared_track_ids)
                         .includes(:track_feature)
                         .limit(10)
    
    {
      count: shared_track_ids.size,
      top_shared: shared_tracks.map { |t| "#{t.song_name} by #{t.artist}" }
    }
  end
  
  # Shared artists analysis
  def self.shared_artists_analysis(user1, user2)
    shared_artist_ids = user1.artists.pluck(:id) & user2.artists.pluck(:id)
    
    shared_artists = Artist.where(id: shared_artist_ids)
                           .order(:name)
                           .limit(10)
    
    {
      count: shared_artist_ids.size,
      top_shared: shared_artists.pluck(:name)
    }
  end
  
  # Shared albums analysis
  def self.shared_albums_analysis(user1, user2)
    shared_album_ids = user1.albums.pluck(:id) & user2.albums.pluck(:id)
    
    shared_albums = Album.where(id: shared_album_ids).limit(10)
    
    {
      count: shared_album_ids.size,
      top_shared: shared_albums.map { |a| "#{a.title || 'Unknown'} by #{a.artist}" }
    }
  end
  
  # Genre compatibility analysis
  def self.genre_compatibility_analysis(user1, user2)
    user1_genres = get_user_genre_distribution(user1)
    user2_genres = get_user_genre_distribution(user2)
    
    shared_genres = user1_genres.keys & user2_genres.keys
    
    {
      user1_top_genres: user1_genres.first(3).map(&:first),
      user2_top_genres: user2_genres.first(3).map(&:first),
      top_shared_genres: shared_genres.first(3)
    }
  end
  
  # Mood compatibility analysis
  def self.mood_compatibility_analysis(user1, user2)
    user1_moods = get_user_mood_distribution(user1)
    user2_moods = get_user_mood_distribution(user2)
    
    {
      user1_dominant_mood: user1_moods.first&.first || "varied",
      user2_dominant_mood: user2_moods.first&.first || "varied",
      mood_alignment: calculate_mood_alignment(user1_moods, user2_moods)
    }
  end
  
  # Anthem compatibility analysis
  def self.anthem_compatibility_analysis(user1, user2)
    result = { same_anthem: false }
    
    if user1.anthem_track_id == user2.anthem_track_id
      result[:same_anthem] = true
      result[:anthem] = Track.find_by(id: user1.anthem_track_id)&.song_name
    else
      result[:user1_anthem] = Track.find_by(id: user1.anthem_track_id)&.song_name
      result[:user2_anthem] = Track.find_by(id: user2.anthem_track_id)&.song_name
      result[:anthem_similarity] = calculate_anthem_compatibility(user1, user2)
    end
    
    result
  end
  
  # Get user genre distribution
  def self.get_user_genre_distribution(user)
    TrackFeature
      .joins(track: :user_tracks)
      .where(user_tracks: { user_id: user.id })
      .where.not(genre: nil)
      .group(:genre)
      .order('COUNT(*) DESC')
      .count
  end
  
  # Get user mood distribution
  def self.get_user_mood_distribution(user)
    TrackFeature
      .joins(track: :user_tracks)
      .where(user_tracks: { user_id: user.id })
      .where.not(mood: nil)
      .group(:mood)
      .order('COUNT(*) DESC')
      .count
  end
  
  # Calculate mood alignment
  def self.calculate_mood_alignment(moods1, moods2)
    return "low" if moods1.empty? || moods2.empty?
    
    # Get top moods
    top_mood1 = moods1.first&.first
    top_mood2 = moods2.first&.first
    
    if top_mood1 == top_mood2
      "high"
    elsif (moods1.keys & moods2.keys).any?
      "medium"
    else
      "low"
    end
  end
  
  # Compare track features similarity
  def self.compare_track_features_similarity(features1, features2)
    score = 0
    count = 0
    
    # Compare genre
    if features1.genre && features2.genre
      score += 25 if features1.genre == features2.genre
      count += 1
    end
    
    # Compare mood
    if features1.mood && features2.mood
      score += 25 if features1.mood == features2.mood
      count += 1
    end
    
    # Compare BPM (within 10% range)
    if features1.bpm && features2.bpm && features1.bpm > 0 && features2.bpm > 0
      bpm_ratio = [features1.bpm, features2.bpm].min.to_f / [features1.bpm, features2.bpm].max
      score += 25 * bpm_ratio
      count += 1
    end
    
    # Compare energy/character
    if features1.character && features2.character
      score += 25 if features1.character == features2.character
      count += 1
    end
    
    count > 0 ? (score / count).round(1) : 0
  end
  
  # Determine compatibility level
  def self.compatibility_level(score)
    case score
    when 90..100
      "Perfect Match"
    when 75..89
      "Very High"
    when 60..74
      "High"
    when 45..59
      "Medium"
    when 30..44
      "Low"
    else
      "Very Low"
    end
  end
  
  # Calculate cosine similarity between two vectors
  def self.cosine_similarity(vec1, vec2)
    return 0 unless vec1.is_a?(Array) && vec2.is_a?(Array) && vec1.size == vec2.size && vec1.size > 0
    
    dot_product = 0
    norm1 = 0
    norm2 = 0
    
    vec1.zip(vec2).each do |v1, v2|
      next unless v1.is_a?(Numeric) && v2.is_a?(Numeric)
      dot_product += v1 * v2
      norm1 += v1 * v1
      norm2 += v2 * v2
    end
    
    return 0 if norm1 == 0 || norm2 == 0
    
    similarity = dot_product / (Math.sqrt(norm1) * Math.sqrt(norm2))
    [[similarity, -1.0].max, 1.0].min
  end
endZZZ