class AddNameAndProfilePhotoToUser < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :display_name, :string
    add_column :users, :profile_photo_url, :string
  end
end
