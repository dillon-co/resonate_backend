class CreateAlbums < ActiveRecord::Migration[8.0]
  def change
    create_table :albums do |t|
      t.string :artist
      t.string :genre
      t.string :mood
      t.integer :energy_level
      t.text :themes

      t.timestamps
    end
  end
end
