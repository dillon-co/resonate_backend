class AddPopularityToAlbumFeatures < ActiveRecord::Migration[8.0]
  def change
    add_column :album_features, :popularity, :integer
  end
end
