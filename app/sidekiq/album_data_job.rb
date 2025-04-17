class AlbumDataJob
  include Sidekiq::Job

  def perform(album_id)
    # Find the album by ID
    album = Album.find_by(id: album_id)
    
    # Process the album if found
    if album
      Rails.logger.info "Processing album data for: #{album.title} by #{album.artist}"
      MusicAnalysisService.process_album(album)
      Rails.logger.info "Completed processing album data for ID: #{album_id}"
    else
      Rails.logger.error "Album with ID #{album_id} not found"
    end
  rescue => e
    Rails.logger.error "Error processing album data for ID #{album_id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise e # Re-raise to trigger Sidekiq retry mechanism
  end
end
