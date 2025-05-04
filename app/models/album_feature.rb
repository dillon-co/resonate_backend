class AlbumFeature < ApplicationRecord
  vectorsearch

  after_save :upsert_to_vectorsearch

  belongs_to :album

  # Define the text content used for vector search embedding
  def vectorsearchable_as_text
    # Combine relevant attributes into a descriptive string
    # Adjust based on available and relevant attributes from AlbumFeature and Album
    [ 
      "Album: #{album.title}",
      "Artist: #{album.artist}", # Assuming album has an artist attribute/association
      ("Genre: #{genre}" if genre.present?),
      ("Era: #{era}" if era.present?),
      ("Mood: #{mood}" if mood.present?),
      ("Themes: #{themes}" if themes.present?),
      ("Instruments: #{instruments}" if instruments.present?)
    ].compact.join(". ")
  end
end
