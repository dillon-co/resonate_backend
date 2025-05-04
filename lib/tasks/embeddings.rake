namespace :embeddings do
  desc "Re-embed all track, artist, and album features, then update user embeddings."
  task regenerate_all: :environment do
    puts "Starting embedding regeneration..."

    # 1. Re-embed Item Features
    puts "Re-embedding TrackFeatures..."
    TrackFeature.find_each do |feature|
      feature.save # Triggers vectorsearch callback with new text
      print '.' # Progress indicator
    rescue => e
      puts "\nError saving TrackFeature #{feature.id}: #{e.message}"
    end
    puts "\nTrackFeatures done."

    puts "Re-embedding ArtistFeatures..."
    ArtistFeature.find_each do |feature|
      feature.save
      print '.'
    rescue => e
      puts "\nError saving ArtistFeature #{feature.id}: #{e.message}"
    end
    puts "\nArtistFeatures done."

    puts "Re-embedding AlbumFeatures..."
    AlbumFeature.find_each do |feature|
      feature.save
      print '.'
    rescue => e
      puts "\nError saving AlbumFeature #{feature.id}: #{e.message}"
    end
    puts "\nAlbumFeatures done."

    # 2. Re-calculate User Embeddings
    puts "Updating User embeddings..."
    User.find_each do |user|
      UserEmbeddingService.update_embedding_for(user)
      print '.'
    rescue => e
      puts "\nError updating embedding for User #{user.id}: #{e.message}"
    end
    puts "\nUser embeddings done."

    # 3. Clear Cache
    puts "Clearing Rails cache..."
    Rails.cache.clear
    puts "Cache cleared."

    puts "Embedding regeneration complete!"
  end
end
