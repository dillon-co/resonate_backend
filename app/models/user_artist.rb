class UserArtist < ApplicationRecord
  belongs_to :user
  belongs_to :artist

  after_create :update_user_embedding

  def update_user_embedding
    UserEmbeddingService.update_embedding_for(self.user)
  end
end
