class FetchUserAnthemJob
  include Sidekiq::Job

  def perform(user_id)
    user = User.find_by(id: user_id)
    unless user
      Rails.logger.warn("FetchUserAnthemJob: User with ID #{user_id} not found.")
      return
    end

    Rails.logger.info("FetchUserAnthemJob: Fetching anthem for user #{user.id}")
    user.update_anthem_track!
  rescue => e
    Rails.logger.error("FetchUserAnthemJob failed for user #{user_id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    # Optionally, implement retry logic or notify an error service
  end
end
