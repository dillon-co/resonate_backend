class UserEmbeddingService
  # Update embedding for a specific user
  def self.update_embedding_for(user)
    return nil unless user&.persisted?
    
    Rails.logger.info("Updating embedding for user #{user.id}")
    
    begin
      # Collect all embeddings with weights
      weighted_embeddings = []
      
      # Get track embeddings with play count weights
      track_data = fetch_track_embeddings(user)
      weighted_embeddings.concat(track_data) if track_data.any?
      
      # Add anthem track with high weight if present
      anthem_data = fetch_anthem_embedding(user)
      weighted_embeddings << anthem_data if anthem_data
      
      # Get artist embeddings with follow/like weights
      artist_data = fetch_artist_embeddings(user)
      weighted_embeddings.concat(artist_data) if artist_data.any?
      
      # Get album embeddings with save/like weights
      album_data = fetch_album_embeddings(user)
      weighted_embeddings.concat(album_data) if album_data.any?
      
      # Check if we have any embeddings
      if weighted_embeddings.empty?
        Rails.logger.warn("No embeddings found for user #{user.id}")
        return nil
      end
      
      # Calculate weighted average embedding
      user_embedding = calculate_weighted_embedding(weighted_embeddings)
      
      # Normalize the embedding
      user_embedding = normalize_embedding(user_embedding)
      
      # Save the embedding
      if user_embedding && valid_embedding?(user_embedding)
        user.update!(embedding: user_embedding)
        Rails.logger.info("Successfully updated embedding for user #{user.id}")
        return user_embedding
      else
        Rails.logger.error("Invalid embedding calculated for user #{user.id}")
        return nil
      end
      
    rescue => e
      Rails.logger.error("Error updating embedding for user #{user.id}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      return nil
    end
  end
  
  # Batch update embeddings for multiple users
  def self.update_embeddings_for_users(user_ids)
    user_ids = Array(user_ids)
    results = { success: [], failed: [] }
    
    User.where(id: user_ids).find_each do |user|
      if update_embedding_for(user)
        results[:success] << user.id
      else
        results[:failed] << user.id
      end
    end
    
    results
  end
  
  # Update embeddings for all users (use with caution)
  def self.update_all_user_embeddings(batch_size: 100)
    total_users = User.count
    processed = 0
    failed = 0
    
    User.find_in_batches(batch_size: batch_size) do |users|
      users.each do |user|
        if update_embedding_for(user)
          processed += 1
        else
          failed += 1
        end
      end
      
      Rails.logger.info("Processed #{processed + failed}/#{total_users} users (#{failed} failures)")
    end
    
    { total: total_users, processed: processed, failed: failed }
  end
  
  private
  
  # Fetch track embeddings with weights based on play count or interaction
  def self.fetch_track_embeddings(user)
    # Using select to get both embedding and weight in one query
    # Note: user_tracks doesn't have play_count in the schema, so using created_at for recency
    TrackFeature
      .joins(track: :user_tracks)
      .where(user_tracks: { user_id: user.id })
      .where.not(embedding: nil)
      .select(
        'track_features.embedding',
        'track_features.popularity',
        'user_tracks.created_at',
        # Weight based on recency - newer tracks get higher weight
        'CASE 
          WHEN user_tracks.created_at > CURRENT_DATE - INTERVAL \'7 days\' THEN 3.0
          WHEN user_tracks.created_at > CURRENT_DATE - INTERVAL \'30 days\' THEN 2.0
          WHEN user_tracks.created_at > CURRENT_DATE - INTERVAL \'90 days\' THEN 1.5
          ELSE 1.0
        END as weight'
      )
      .map do |record|
        # Adjust weight based on popularity (if available)
        popularity_boost = record.popularity ? (1 + (record.popularity / 100.0) * 0.5) : 1.0
        
        {
          embedding: parse_embedding(record.embedding),
          weight: record.weight.to_f * popularity_boost
        }
      end
  rescue => e
    Rails.logger.error("Error fetching track embeddings: #{e.message}")
    []
  end
  
  # Fetch artist embeddings with weights
  def self.fetch_artist_embeddings(user)
    ArtistFeature
      .joins(artist: :user_artists)
      .where(user_artists: { user_id: user.id })
      .where.not(embedding: nil)
      .select(
        'artist_features.embedding',
        'artist_features.popularity',
        'user_artists.created_at',
        # Since there's no is_favorite or follow_date, use recency and popularity
        'CASE 
          WHEN user_artists.created_at > CURRENT_DATE - INTERVAL \'7 days\' THEN 2.5
          WHEN user_artists.created_at > CURRENT_DATE - INTERVAL \'30 days\' THEN 2.0
          ELSE 1.5
        END as weight'
      )
      .map do |record|
        {
          embedding: parse_embedding(record.embedding),
          weight: record.weight.to_f
        }
      end
  rescue => e
    Rails.logger.error("Error fetching artist embeddings: #{e.message}")
    []
  end
  
  # Fetch album embeddings with weights
  def self.fetch_album_embeddings(user)
    AlbumFeature
      .joins(album: :user_albums)
      .where(user_albums: { user_id: user.id })
      .where.not(embedding: nil)
      .select(
        'album_features.embedding',
        'album_features.popularity',
        'user_albums.created_at',
        # Weight based on recency
        'CASE 
          WHEN user_albums.created_at > CURRENT_DATE - INTERVAL \'7 days\' THEN 2.0
          WHEN user_albums.created_at > CURRENT_DATE - INTERVAL \'30 days\' THEN 1.5
          ELSE 1.0
        END as weight'
      )
      .map do |record|
        {
          embedding: parse_embedding(record.embedding),
          weight: record.weight.to_f
        }
      end
  rescue => e
    Rails.logger.error("Error fetching album embeddings: #{e.message}")
    []
  end
  
  # Fetch anthem track embedding with high weight
  def self.fetch_anthem_embedding(user)
    return nil unless user.anthem_track_id
    
    track_feature = TrackFeature
      .where(track_id: user.anthem_track_id)
      .where.not(embedding: nil)
      .first
    
    return nil unless track_feature
    
    {
      embedding: parse_embedding(track_feature.embedding),
      weight: 5.0  # Anthem tracks get highest weight
    }
  rescue => e
    Rails.logger.error("Error fetching anthem embedding: #{e.message}")
    nil
  end
  
  # Parse embedding from database format
  def self.parse_embedding(embedding)
    case embedding
    when Array
      embedding
    when String
      # Handle JSON string format
      JSON.parse(embedding)
    else
      # Handle PostgreSQL array format or other formats
      embedding.to_a
    end
  rescue => e
    Rails.logger.error("Error parsing embedding: #{e.message}")
    nil
  end
  
  # Calculate weighted average embedding
  def self.calculate_weighted_embedding(weighted_embeddings)
    return nil if weighted_embeddings.empty?
    
    # Filter out invalid embeddings
    valid_embeddings = weighted_embeddings.select do |item|
      item[:embedding] && item[:embedding].is_a?(Array) && item[:embedding].any?
    end
    
    return nil if valid_embeddings.empty?
    
    # Get dimension from first valid embedding
    dimension = valid_embeddings.first[:embedding].size
    
    # Initialize weighted sum and total weight
    weighted_sum = Array.new(dimension, 0.0)
    total_weight = 0.0
    
    # Calculate weighted sum
    valid_embeddings.each do |item|
      embedding = item[:embedding]
      weight = item[:weight] || 1.0
      
      # Skip if dimension mismatch
      next unless embedding.size == dimension
      
      # Add weighted values
      dimension.times do |i|
        weighted_sum[i] += embedding[i] * weight
      end
      
      total_weight += weight
    end
    
    # Return nil if no valid embeddings were processed
    return nil if total_weight == 0
    
    # Calculate weighted average
    weighted_sum.map { |val| val / total_weight }
  end
  
  # Normalize embedding to unit length
  def self.normalize_embedding(embedding)
    return nil unless embedding && embedding.is_a?(Array)
    
    # Calculate magnitude
    magnitude = Math.sqrt(embedding.sum { |val| val * val })
    
    # Avoid division by zero
    return embedding if magnitude == 0
    
    # Normalize
    embedding.map { |val| val / magnitude }
  end
  
  # Validate embedding
  def self.valid_embedding?(embedding)
    return false unless embedding.is_a?(Array)
    return false if embedding.empty?
    return false unless embedding.all? { |val| val.is_a?(Numeric) }
    return false if embedding.all? { |val| val == 0 }
    
    # Check for NaN or Infinity
    return false if embedding.any? { |val| val.nan? || val.infinite? }
    
    true
  end
  
  # Calculate simple average embedding (legacy method for backward compatibility)
  def self.calculate_average_embedding(embeddings)
    return nil if embeddings.empty?
    
    # Convert to weighted format with equal weights
    weighted_embeddings = embeddings.map do |embedding|
      { embedding: embedding, weight: 1.0 }
    end
    
    calculate_weighted_embedding(weighted_embeddings)
  end
  
  # Get similar users based on embedding distance
  def self.find_similar_users(user, limit: 10, threshold: 0.8)
    return [] unless user.embedding.present?
    
    user_embedding = parse_embedding(user.embedding)
    return [] unless valid_embedding?(user_embedding)
    
    similar_users = []
    
    User.where.not(id: user.id)
        .where.not(embedding: nil)
        .find_each do |other_user|
      other_embedding = parse_embedding(other_user.embedding)
      next unless valid_embedding?(other_embedding)
      
      # Calculate cosine similarity
      similarity = cosine_similarity(user_embedding, other_embedding)
      
      if similarity >= threshold
        similar_users << { user: other_user, similarity: similarity }
      end
    end
    
    # Sort by similarity and take top N
    similar_users.sort_by { |item| -item[:similarity] }
                 .first(limit)
  end
  
  # Calculate cosine similarity between two embeddings
  def self.cosine_similarity(embedding1, embedding2)
    return 0.0 unless embedding1.size == embedding2.size
    
    dot_product = 0.0
    norm1 = 0.0
    norm2 = 0.0
    
    embedding1.size.times do |i|
      dot_product += embedding1[i] * embedding2[i]
      norm1 += embedding1[i] * embedding1[i]
      norm2 += embedding2[i] * embedding2[i]
    end
    
    return 0.0 if norm1 == 0 || norm2 == 0
    
    dot_product / (Math.sqrt(norm1) * Math.sqrt(norm2))
  end
end