class AddPreviewUrlToTracks < ActiveRecord::Migration[8.0]
  def change
    add_column :tracks, :preview_url, :string
  end
end
