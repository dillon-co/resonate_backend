class CreateAlbumFeatures < ActiveRecord::Migration[8.0]
  def change
    create_table :album_features do |t|
      t.belongs_to :album, null: false, foreign_key: true
      t.string :genre
      t.string :era
      t.string :instruments
      t.string :mood
      t.text :themes
      t.integer :num_tracks
      t.float :length

      t.timestamps
    end
  end
end
