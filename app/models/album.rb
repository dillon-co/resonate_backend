class Album < ApplicationRecord
    has_many :album_features
    has_many :user_albums
    has_many :users, through: :user_albums, source: :user
    after_commit :process_album, on: :create

    def process_album
        AlbumDataJob.perform_async(self.id)
    end 
end
