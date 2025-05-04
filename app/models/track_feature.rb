class TrackFeature < ApplicationRecord
  vectorsearch

  after_save :upsert_to_vectorsearch

  belongs_to :track

  after_save :update_user_embedding

  # Define the text content used for vector search embedding
  def vectorsearchable_as_text
    # Combine relevant attributes into a descriptive string
    # Adjust based on available and relevant attributes from TrackFeature and Track
    [ 
      "Track: #{track.song_name}",
      "Artist: #{track.artist}",
      ("Genre: #{genre}" if genre.present?),
      ("Mood: #{mood}" if mood.present?),
      ("Character: #{character}" if character.present?),
      ("Movement: #{movement}" if movement.present?),
      ("Emotion: #{emotion}" if emotion.present?),
      ("Instruments: #{instruments}" if instruments.present?)
      # Consider adding album name if available: track.album.title
    ].compact.join(". ")
  end

  def update_user_embedding
    users = self.track.users
    users.each do |user|
      UserEmbeddingJob.perform_async(user.id)
    end
  end

  # vectorsearch

  # after_save :upsert_to_vectorsearch
end
