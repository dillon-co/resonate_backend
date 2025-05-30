class MusicCompatibilityService
  # Calculate musical compatibility between two users
  def self.calculate_compatibility(user1, user2, depth: :shallow)
    # Check if both users have embeddings - if so, use embedding-based compatibility
    if user1.embedding.present? && user2.embedding.present?
      return calculate_embedding_compatibility(user1, user2)
    end
    0
  end
  
  # Calculate compatibility using user embeddings based on Cosine Similarity
  def self.calculate_embedding_compatibility(user1, user2)
    # Ensure both users have embeddings
    unless user1.embedding.present? && user2.embedding.present?
      # Try to generate embeddings if not present
      UserEmbeddingService.update_embedding_for(user1) unless user1.embedding.present?
      UserEmbeddingService.update_embedding_for(user2) unless user2.embedding.present?
      
      # Reload to get updated embeddings
      user1.reload
      user2.reload
      
      # If still no embeddings, return a default low score
      unless user1.embedding.present? && user2.embedding.present?
        Rails.logger.warn("Could not generate embeddings for compatibility check between users #{user1.id} and #{user2.id}. Returning 0.")
        return 0
      end
    end
    
    # Cache key for the compatibility score
    cache_key = "user_compatibility:#{[user1.id, user2.id].sort.join('-')}:cosine:#{user1.updated_at.to_i}-#{user2.updated_at.to_i}"
    
    # Try to get from cache first
    cached_score = Rails.cache.read(cache_key)
    return cached_score if cached_score.present?
    
    # Parse embeddings to handle different formats
    embedding1 = parse_embedding(user1.embedding)
    embedding2 = parse_embedding(user2.embedding)
    
    # Calculate Cosine Similarity
    similarity = cosine_similarity(embedding1, embedding2)
    
    # Convert similarity score from [-1, 1] range to [0, 100] scale
    # (similarity + 1) maps [-1, 1] to [0, 2]
    # / 2 maps [0, 2] to [0, 1]
    # * 100 maps [0, 1] to [0, 100]
    similarity_score = ((similarity + 1.0) / 2.0) * 100
    
    # Round the score
    score = similarity_score.round(1)
    
    # Cache the result
    Rails.cache.write(cache_key, score, expires_in: 1.day)
    
    score
  end

  # Helper method to calculate Euclidean distance (Keep for potential other uses)
  def self.calculate_euclidean_distance(vec1, vec2)
    return Float::INFINITY unless vec1.is_a?(Array) && vec2.is_a?(Array) && vec1.size == vec2.size && vec1.size > 0

    sum_of_squares = 0
    vec1.zip(vec2).each do |v1, v2|
      next unless v1.is_a?(Numeric) && v2.is_a?(Numeric)
      sum_of_squares += (v1 - v2)**2
    end

    Math.sqrt(sum_of_squares)
  end

  # Calculate cosine similarity between two vectors
  def self.cosine_similarity(vec1, vec2)
    return 0 unless vec1.is_a?(Array) && vec2.is_a?(Array) && vec1.size == vec2.size && vec1.size > 0

    dot_product = 0
    norm1 = 0
    norm2 = 0
    vec1.zip(vec2).each do |v1, v2|
      # Ensure v1 and v2 are numeric before calculation
      next unless v1.is_a?(Numeric) && v2.is_a?(Numeric)
      dot_product += v1 * v2
      norm1 += v1 * v1
      norm2 += v2 * v2
    end

    # Handle cases where norms are zero (e.g., zero vectors)
    return 0 if norm1 == 0 || norm2 == 0

    similarity = dot_product / (Math.sqrt(norm1) * Math.sqrt(norm2))

    # Clamp result to [-1, 1] to handle potential floating-point inaccuracies
    [[similarity, -1.0].max, 1.0].min
  end
  
  private
  
  # Parse embedding from various formats (pgvector returns strings in some cases)
  def self.parse_embedding(embedding)
    case embedding
    when Array
      embedding
    when String
      # Handle JSON string format
      JSON.parse(embedding)
    else
      # Handle PostgreSQL array format
      embedding.to_a
    end
  rescue => e
    Rails.logger.error("Error parsing embedding: #{e.message}")
    []
  end
  
  # Determine time range based on compatibility depth
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