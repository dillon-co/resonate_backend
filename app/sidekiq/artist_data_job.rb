class ArtistDataJob
  include Sidekiq::Job

  def perform(artist_id)
    # Find the artist by ID
    artist = Artist.find_by(id: artist_id)
    
    # Process the artist if found
    if artist
      Rails.logger.info "Processing artist data for: #{artist.name}"
      MusicAnalysisService.process_artist(artist)
      Rails.logger.info "Completed processing artist data for ID: #{artist_id}"
    else
      Rails.logger.error "Artist with ID #{artist_id} not found"
    end
  rescue => e
    Rails.logger.error "Error processing artist data for ID #{artist_id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise e # Re-raise to trigger Sidekiq retry mechanism
  end
end
