class MusicCompatibilityService
  # Calculate musical compatibility between two users
  def self.calculate_compatibility(user1, user2, depth: :shallow)
    # Check if both users have embeddings - if so, use embedding-based compatibility
    if user1.embedding.present? && user2.embedding.present?
      return calculate_embedding_compatibility(user1, user2)
    end
    
    # Fall back to traditional compatibility calculation if embeddings aren't available
    # Get time range based on depth
    time_range = time_range_for_depth(depth)
    
    # Get cached data or fetch if not available
    user1_artists = Rails.cache.fetch("user:#{user1.id}:top_artists:#{time_range}", expires_in: 1.day) do
      user1.get_top_artists(time_range: time_range)
    end
    
    user2_artists = Rails.cache.fetch("user:#{user2.id}:top_artists:#{time_range}", expires_in: 1.day) do
      user2.get_top_artists(time_range: time_range)
    end
    
    # Ensure we have arrays
    user1_artists = user1_artists.is_a?(Array) ? user1_artists : []
    user2_artists = user2_artists.is_a?(Array) ? user2_artists : []
    
    # Extract IDs
    user1_artist_ids = user1_artists.map { |a| a[:id] }
    user2_artist_ids = user2_artists.map { |a| a[:id] }
    
    # Calculate artist overlap using Jaccard similarity
    artist_similarity = calculate_artist_similarity(user1_artist_ids, user2_artist_ids)
    
    # Get tracks for both users
    user1_tracks = Rails.cache.fetch("user:#{user1.id}:top_tracks:#{time_range}", expires_in: 1.day) do
      user1.get_top_tracks(time_range: time_range)
    end
    
    user2_tracks = Rails.cache.fetch("user:#{user2.id}:top_tracks:#{time_range}", expires_in: 1.day) do
      user2.get_top_tracks(time_range: time_range)
    end
    
    # Ensure we have arrays
    user1_tracks = user1_tracks.is_a?(Array) ? user1_tracks : []
    user2_tracks = user2_tracks.is_a?(Array) ? user2_tracks : []
    
    # Calculate track similarity using Last.fm data
    track_similarity = 0
    genre_similarity = 0
    
    if !user1_tracks.empty? && !user2_tracks.empty?
      # Use MusicAnalysisService to analyze tracks with Last.fm
      user1_analysis = MusicAnalysisService.analyze_tracks(user1_tracks)
      user2_analysis = MusicAnalysisService.analyze_tracks(user2_tracks)
      
      # Compare track features
      track_similarity = compare_track_features(user1_analysis, user2_analysis)
      
      # Compare genres
      genre_similarity = compare_genres(user1_analysis, user2_analysis)
    end
    
    # Combine metrics with weights (adjusted for Last.fm data)
    overall_score = (artist_similarity * 0.4) + (track_similarity * 0.4) + (genre_similarity * 0.2)
    
    # Return score as percentage
    (overall_score * 100).round(1)
  end
  
  # Calculate compatibility using user embeddings
  def self.calculate_embedding_compatibility(user1, user2)
    # Ensure both users have embeddings
    unless user1.embedding.present? && user2.embedding.present?
      # Generate embeddings if not present
      UserEmbeddingService.update_embedding_for(user1) unless user1.embedding.present?
      UserEmbeddingService.update_embedding_for(user2) unless user2.embedding.present?
      
      # If still no embeddings, fall back to traditional method
      if !user1.embedding.present? || !user2.embedding.present?
        Rails.logger.warn("Could not generate embeddings for users, falling back to traditional compatibility")
        return calculate_compatibility(user1, user2, depth: :deep)
      end
    end
    
    # Cache key for the compatibility score
    cache_key = "user_compatibility:#{[user1.id, user2.id].sort.join('-')}:#{user1.updated_at.to_i}-#{user2.updated_at.to_i}"
    
    # Try to get from cache first
    cached_score = Rails.cache.read(cache_key)
    return cached_score if cached_score.present?
    
    # Calculate cosine similarity between user embeddings
    similarity = cosine_similarity(user1.embedding, user2.embedding)
    
    # Convert similarity to percentage (0-100 scale)
    # Cosine similarity ranges from -1 to 1, so we normalize to 0-100
    score = ((similarity + 1) / 2 * 100).round(1)
    
    # Cache the result
    Rails.cache.write(cache_key, score, expires_in: 1.day)
    
    score
  end
  
  # Calculate cosine similarity between two vectors
  def self.cosine_similarity(vec1, vec2)
    # Use the Neighbor gem's cosine distance and convert to similarity
    # Cosine distance = 1 - cosine similarity, so similarity = 1 - distance
    return 0 unless vec1.is_a?(Array) && vec2.is_a?(Array) && vec1.size == vec2.size
    
    # Create a temporary index with just one vector
    index = Neighbor::Index.new(dimensions: vec1.size, metric: :cosine)
    index.add(1, vec1)
    
    # Find the nearest neighbor (which will be the only one in the index)
    nearest = index.nearest_neighbors(vec2, k: 1)
    
    # If no neighbors found (shouldn't happen), return 0
    return 0 if nearest.empty?
    
    # Convert distance to similarity (cosine distance = 1 - cosine similarity)
    # nearest[0][1] contains the distance
    1 - nearest[0][1]
  end
  
  private
  
  def self.time_range_for_depth(depth)
    case depth
    when :shallow
      'short_term'
    when :medium
      'medium_term'
    when :deep
      'long_term'
    else
      'medium_term'
    end
  end
  
  def self.calculate_artist_similarity(artist_ids1, artist_ids2)
    common_artists = artist_ids1 & artist_ids2
    total_artists = artist_ids1 | artist_ids2
    
    total_artists.empty? ? 0 : (common_artists.size.to_f / total_artists.size)
  end
  
  def self.compare_track_features(analysis1, analysis2)
    # If either analysis is missing, return 0
    return 0 if analysis1.blank? || analysis2.blank?
    
    # Get overall features from both analyses
    features1 = analysis1[:overall_features] || {}
    features2 = analysis2[:overall_features] || {}
    
    # Features to compare
    compared_features = [:energy, :mood, :danceability, :acousticness]
    
    # Calculate distance between feature vectors
    total_difference = 0
    feature_count = 0
    
    compared_features.each do |feature|
      # Skip if either value is nil
      next unless features1[feature] && features2[feature]
      
      # Calculate absolute difference
      total_difference += (features1[feature].to_f - features2[feature].to_f).abs
      feature_count += 1
    end
    
    # Avoid division by zero
    return 0 if feature_count == 0
    
    # Convert distance to similarity (0 to 1 scale)
    1 - (total_difference / feature_count)
  end
  
  def self.compare_genres(analysis1, analysis2)
    # If either analysis is missing, return 0
    return 0 if analysis1.blank? || analysis2.blank?
    
    # Get tags from both analyses
    tags1 = analysis1[:overall_features]&.dig(:tags) || []
    tags2 = analysis2[:overall_features]&.dig(:tags) || []
    
    # Calculate Jaccard similarity for tags
    common_tags = tags1 & tags2
    total_tags = tags1 | tags2
    
    tag_similarity = total_tags.empty? ? 0 : (common_tags.size.to_f / total_tags.size)
    
    # Get genres if available
    genre1 = analysis1[:overall_features]&.dig(:genre)
    genre2 = analysis2[:overall_features]&.dig(:genre)
    
    # If both users have a primary genre and they match, boost similarity
    genre_match = (genre1 && genre2 && genre1 == genre2) ? 1.0 : 0.0
    
    # Combine tag similarity with genre match (weighted)
    (tag_similarity * 0.7) + (genre_match * 0.3)
  end
end
