class CreateArtistFeatures < ActiveRecord::Migration[8.0]
  def change
    create_table :artist_features do |t|
      t.belongs_to :artist, null: false, foreign_key: true
      t.string :genre
      t.string :era
      t.string :instruments
      t.string :mood
      t.text :themes
      t.integer :energy_level
      

      t.timestamps
    end
  end
end
