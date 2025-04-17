class AddVectorColumnToArtistFeatures < ActiveRecord::Migration[8.0]
  def change
    add_column :artist_features, :embedding, :vector,
      limit: LangchainrbRails
        .config
        .vectorsearch
        .llm
        .default_dimensions
  end
end
