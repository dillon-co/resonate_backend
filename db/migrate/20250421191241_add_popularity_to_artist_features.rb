class AddPopularityToArtistFeatures < ActiveRecord::Migration[8.0]
  def change
    add_column :artist_features, :popularity, :integer
  end
end
