class CreateUserArtists < ActiveRecord::Migration[8.0]
  def change
    create_table :user_artists do |t|
      t.belongs_to :user, null: false, foreign_key: true
      t.belongs_to :artist, null: false, foreign_key: true

      t.timestamps
    end
  end
end
