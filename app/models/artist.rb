class Artist < ApplicationRecord
    has_many :artist_features
    has_many :user_artists
    has_many :users, through: :user_artists, source: :user
    after_commit :process_artist, on: :create

    def process_artist
        ArtistDataJob.perform_async(self.id)
    end
end
