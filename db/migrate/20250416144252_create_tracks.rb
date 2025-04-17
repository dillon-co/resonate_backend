class CreateTracks < ActiveRecord::Migration[8.0]
  def change
    create_table :tracks do |t|
      t.string :artist
      t.string :song_name
      t.string :spotify_id
      t.string :image_url

      t.timestamps
    end
  end
end
