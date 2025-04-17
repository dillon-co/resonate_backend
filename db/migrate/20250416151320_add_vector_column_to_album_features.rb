class AddVectorColumnToAlbumFeatures < ActiveRecord::Migration[8.0]
  def change
    add_column :album_features, :embedding, :vector,
      limit: LangchainrbRails
        .config
        .vectorsearch
        .llm
        .default_dimensions
  end
end
