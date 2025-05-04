class ChangeTrackFeatureEmbeddingDimension < ActiveRecord::Migration[8.0]
  def change
    execute "ALTER TABLE track_features ALTER COLUMN embedding TYPE vector(512);"
  end
end
