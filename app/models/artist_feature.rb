class ArtistFeature < ApplicationRecord
  vectorsearch

  after_save :upsert_to_vectorsearch

  belongs_to :artist

  # Define the text content used for vector search embedding
  def vectorsearchable_as_text
    # Combine relevant attributes into a descriptive string
    # Adjust based on available and relevant attributes
    [ 
      "Artist: #{artist.name}",
      ("Genre: #{genre}" if genre.present?),
      ("Era: #{era}" if era.present?),
      ("Mood: #{mood}" if mood.present?),
      ("Themes: #{themes}" if themes.present?),
      ("Instruments: #{instruments}" if instruments.present?)
      # Add more relevant text data if available (e.g., bio, tags from another source)
    ].compact.join(". ")
  end
end
