class TrackDataJob
  include Sidekiq::Job

  def perform(track_id)
    # Find the track by ID
    track = Track.find_by(id: track_id)
    
    # Process the track if found
    if track
      Rails.logger.info "Processing track data for: #{track.song_name} by #{track.artist}"
      MusicAnalysisService.process_track(track)
      Rails.logger.info "Completed processing track data for ID: #{track_id}"
    else
      Rails.logger.error "Track with ID #{track_id} not found"
    end
  rescue => e
    Rails.logger.error "Error processing track data for ID #{track_id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise e # Re-raise to trigger Sidekiq retry mechanism
  end
end
