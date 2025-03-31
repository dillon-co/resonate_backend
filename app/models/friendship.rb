class Friendship < ApplicationRecord
  belongs_to :user
  belongs_to :friend, class_name: 'User'
  
  # Add status for friend requests
  enum :status, { pending: 0, accepted: 1, rejected: 2 }
  
  validates :user_id, uniqueness: { scope: :friend_id }
  validate :not_self_friendship
  
  scope :accepted, -> { where(status: :accepted) }
  scope :pending, -> { where(status: :pending) }
  scope :rejected, -> { where(status: :rejected) }
  
  private
  
  # Prevent users from friending themselves
  def not_self_friendship
    if user_id == friend_id
      errors.add(:friend_id, "can't be the same as user")
    end
  end
end