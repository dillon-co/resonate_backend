class UserEmbeddingService
  def self.update_embedding_for(user)
    # Get track embeddings from track_features
    track_embeddings = TrackFeature.joins("INNER JOIN tracks ON track_features.track_id = tracks.id
                                          INNER JOIN user_tracks ON user_tracks.track_id = tracks.id")
                                  .where(user_tracks: { user_id: user.id })
                                  .where.not(embedding: nil)
                                  .pluck(:embedding)
    
    # Get artist embeddings from artist_features
    artist_embeddings = ArtistFeature.joins("INNER JOIN artists ON artist_features.artist_id = artists.id
                                            INNER JOIN user_artists ON user_artists.artist_id = artists.id")
                                    .where(user_artists: { user_id: user.id })
                                    .where.not(embedding: nil)
                                    .pluck(:embedding)
    
    # Get album embeddings from album_features - using the correct join to user_albums with artist_id
    album_embeddings = AlbumFeature.joins("INNER JOIN albums ON album_features.album_id = albums.id")
                                  .joins("INNER JOIN user_albums ON user_albums.album_id = albums.id")
                                  .where(user_albums: { user_id: user.id })
                                  .where.not(embedding: nil)
                                  .pluck(:embedding)
    
    # Calculate average embeddings for each type if available
    avg_track_embedding = calculate_average_embedding(track_embeddings) if track_embeddings.any?
    avg_artist_embedding = calculate_average_embedding(artist_embeddings) if artist_embeddings.any?
    avg_album_embedding = calculate_average_embedding(album_embeddings) if album_embeddings.any?
    
    # Combine all available embeddings with equal weighting
    available_embeddings = [
      avg_track_embedding,
      avg_artist_embedding,
      avg_album_embedding
    ].compact
    
    # Calculate the final user embedding (average of all type averages)
    user_embedding = calculate_average_embedding(available_embeddings) if available_embeddings.any?
    
    # Save the embedding to the user model if we have one
    if user_embedding
      # Assuming user has an embedding field
      user.update(embedding: user_embedding)
      return user_embedding
    end
    
    nil
  end
  
  private
  
  # Calculate the average embedding from an array of embeddings
  def self.calculate_average_embedding(embeddings)
    return nil if embeddings.empty?
    
    # Get the dimension of the embeddings
    dimension = embeddings.first.size
    
    # Initialize sum array with zeros
    sum = Array.new(dimension, 0.0)
    
    # Sum all embeddings
    embeddings.each do |embedding|
      dimension.times do |i|
        sum[i] += embedding[i]
      end
    end
    
    # Divide by count to get average
    sum.map { |val| val / embeddings.size }
  end
end