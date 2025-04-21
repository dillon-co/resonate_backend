class AddPopularityToTrackFeatures < ActiveRecord::Migration[8.0]
  def change
    add_column :track_features, :popularity, :integer
  end
end
