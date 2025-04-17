class CreateTrackFeatures < ActiveRecord::Migration[8.0]
  def change
    create_table :track_features do |t|
      t.belongs_to :track, null: false, foreign_key: true
      t.string :genre
      t.integer :bpm
      t.string :mood
      t.string :character
      t.string :movement
      t.boolean :vocals
      t.string :emotion
      t.string :emotional_dynamics
      t.text :instruments
      t.float :length

      t.timestamps
    end
  end
end
