class CreateArtists < ActiveRecord::Migration[8.0]
  def change
    create_table :artists do |t|
      t.string :name
      t.string :genre
      t.string :image_url
      t.string :spotify_id

      t.timestamps
    end
  end
end
