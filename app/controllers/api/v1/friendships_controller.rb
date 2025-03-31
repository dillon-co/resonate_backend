class Api::V1::FriendshipsController < ApplicationController
  before_action :authenticate_user!
  
  # GET /api/v1/friendships
  # Get all friendships for the current user
  def index
    friendships = Current.user.friendships.includes(:friend)
    received_friendships = Current.user.received_friendships.includes(:user)
    
    render json: {
      sent: friendships.map { |f| friendship_json(f, :friend) },
      received: received_friendships.map { |f| friendship_json(f, :user) }
    }
  end
  
  # GET /api/v1/friendships/accepted
  # Get all accepted friendships
  def accepted
    friends = Current.user.friends
    received_friends = Current.user.received_friends
    
    render json: {
      friends: (friends + received_friends).uniq.map { |f| user_json(f) }
    }
  end
  
  # POST /api/v1/friendships
  # Create a new friendship request
  def create
    friend = User.find(params[:friend_id])
    friendship = Current.user.friendships.new(friend: friend, status: :pending)
    
    if friendship.save
      render json: { friendship: friendship_json(friendship, :friend) }, status: :created
    else
      render json: { errors: friendship.errors.full_messages }, status: :unprocessable_entity
    end
  end
  
  # PATCH /api/v1/friendships/:id/accept
  # Accept a friendship request
  def accept
    friendship = Current.user.received_friendships.find(params[:id])
    friendship.accepted!
    
    render json: { friendship: friendship_json(friendship, :user) }
  end
  
  # PATCH /api/v1/friendships/:id/reject
  # Reject a friendship request
  def reject
    friendship = Current.user.received_friendships.find(params[:id])
    friendship.rejected!
    
    render json: { friendship: friendship_json(friendship, :user) }
  end
  
  # DELETE /api/v1/friendships/:id
  # Delete a friendship
  def destroy
    friendship = Current.user.friendships.find_by(id: params[:id]) || 
                Current.user.received_friendships.find_by(id: params[:id])
                
    if friendship&.destroy
      render json: { success: true }
    else
      render json: { errors: ["Friendship not found"] }, status: :not_found
    end
  end
  
  private
  
  def friendship_json(friendship, relation)
    other_user = friendship.send(relation)
    {
      id: friendship.id,
      status: friendship.status,
      created_at: friendship.created_at,
      user: user_json(other_user)
    }
  end
  
  def user_json(user)
    {
      id: user.id,
      display_name: user.display_name,
      profile_photo_url: user.profile_photo_url,
      compatibility: Current.user.musical_compatibility_with(user)
    }
  end
end
