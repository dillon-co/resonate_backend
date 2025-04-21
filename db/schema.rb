# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2025_04_21_193236) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "vector"

  create_table "album_features", force: :cascade do |t|
    t.bigint "album_id", null: false
    t.string "genre"
    t.string "era"
    t.string "instruments"
    t.string "mood"
    t.text "themes"
    t.integer "num_tracks"
    t.float "length"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.vector "embedding", limit: 1536
    t.integer "popularity"
    t.index ["album_id"], name: "index_album_features_on_album_id"
  end

  create_table "albums", force: :cascade do |t|
    t.string "artist"
    t.string "genre"
    t.string "mood"
    t.integer "energy_level"
    t.text "themes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "artist_features", force: :cascade do |t|
    t.bigint "artist_id", null: false
    t.string "genre"
    t.string "era"
    t.string "instruments"
    t.string "mood"
    t.text "themes"
    t.integer "energy_level"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.vector "embedding", limit: 1536
    t.integer "popularity"
    t.index ["artist_id"], name: "index_artist_features_on_artist_id"
  end

  create_table "artists", force: :cascade do |t|
    t.string "name"
    t.string "genre"
    t.string "image_url"
    t.string "spotify_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "friendships", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "friend_id", null: false
    t.integer "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["friend_id"], name: "index_friendships_on_friend_id"
    t.index ["user_id", "friend_id"], name: "index_friendships_on_user_id_and_friend_id", unique: true
    t.index ["user_id"], name: "index_friendships_on_user_id"
  end

  create_table "omni_auth_identities", force: :cascade do |t|
    t.string "uid"
    t.string "provider"
    t.bigint "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_omni_auth_identities_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.string "token"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "signups", force: :cascade do |t|
    t.string "email", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "track_features", force: :cascade do |t|
    t.bigint "track_id", null: false
    t.string "genre"
    t.integer "bpm"
    t.string "mood"
    t.string "character"
    t.string "movement"
    t.boolean "vocals"
    t.string "emotion"
    t.string "emotional_dynamics"
    t.text "instruments"
    t.float "length"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.vector "embedding", limit: 1536
    t.integer "popularity"
    t.index ["track_id"], name: "index_track_features_on_track_id"
  end

  create_table "tracks", force: :cascade do |t|
    t.string "artist"
    t.string "song_name"
    t.string "spotify_id"
    t.string "image_url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "preview_url"
  end

  create_table "user_albums", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "album_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["album_id"], name: "index_user_albums_on_album_id"
    t.index ["user_id"], name: "index_user_albums_on_user_id"
  end

  create_table "user_artists", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "artist_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["artist_id"], name: "index_user_artists_on_artist_id"
    t.index ["user_id"], name: "index_user_artists_on_user_id"
  end

  create_table "user_tracks", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "track_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["track_id"], name: "index_user_tracks_on_track_id"
    t.index ["user_id"], name: "index_user_tracks_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "display_name"
    t.string "profile_photo_url"
    t.string "spotify_id"
    t.string "spotify_access_token"
    t.string "spotify_refresh_token"
    t.datetime "spotify_token_expires_at"
    t.integer "role", default: 0
    t.vector "embedding", limit: 1536
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "album_features", "albums"
  add_foreign_key "artist_features", "artists"
  add_foreign_key "friendships", "users"
  add_foreign_key "friendships", "users", column: "friend_id"
  add_foreign_key "omni_auth_identities", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "track_features", "tracks"
  add_foreign_key "user_albums", "albums"
  add_foreign_key "user_albums", "users"
  add_foreign_key "user_artists", "artists"
  add_foreign_key "user_artists", "users"
  add_foreign_key "user_tracks", "tracks"
  add_foreign_key "user_tracks", "users"
end
