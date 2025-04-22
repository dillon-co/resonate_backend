class AddAnthemTrackToUsers < ActiveRecord::Migration[8.0]
  def change
    add_reference :users, :anthem_track, null: true, foreign_key: { to_table: :tracks }
  end
end
