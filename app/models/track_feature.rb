class TrackFeature < ApplicationRecord
  vectorsearch

  after_save :upsert_to_vectorsearch

  belongs_to :track

  after_save :update_user_embedding

  def update_user_embedding
    users = self.track.users
    users.each do |user|
      UserEmbeddingJob.perform_async(user.id)
    end
  end

  # vectorsearch

  # after_save :upsert_to_vectorsearch
end
