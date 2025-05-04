class ChangeUserEmbeddingDimension < ActiveRecord::Migration[8.0]
  def change
    execute "ALTER TABLE users ALTER COLUMN embedding TYPE vector(512);" 
  end
end
