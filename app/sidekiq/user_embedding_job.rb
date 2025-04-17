class UserEmbeddingJob
  include Sidekiq::Job

  def perform(user_id)
    user = User.find(user_id)
    UserEmbeddingService.update_embedding_for(user)
  end
end
