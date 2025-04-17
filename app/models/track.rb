class Track < ApplicationRecord
    has_many :track_features
    has_many :user_tracks
    has_many :users, through: :user_tracks, source: :user
    after_commit :process_track, on: :create

    def process_track
        TrackDataJob.perform_async(self.id)
    end
end
