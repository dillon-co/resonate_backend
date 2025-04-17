class ArtistFeature < ApplicationRecord
  vectorsearch

  after_save :upsert_to_vectorsearch

  belongs_to :artist
end
