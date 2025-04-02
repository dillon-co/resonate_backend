class Api::V1::AdminController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin
  
  def users
    Rails.logger.info("Admin#users called by user #{Current.user.id} with role #{Current.user.role}")
    users = User.all.order(created_at: :desc)
    
    render json: users.map { |user| 
      {
        id: user.id,
        display_name: user.display_name,
        email_address: user.email_address,
        role: user.role,
        profile_photo_url: user.profile_photo_url,
        created_at: user.created_at,
        spotify_connected: user.spotify_access_token.present?
      }
    }
  end
  
  def update_user_role
    Rails.logger.info("Admin#update_user_role called by user #{Current.user.id} with role #{Current.user.role}")
    user = User.find(params[:id])
    
    if user.update(role: params[:role])
      render json: { success: true, message: "User role updated successfully" }
    else
      render json: { success: false, error: user.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  end
  
  def metrics
    Rails.logger.info("Admin#metrics called by user #{Current.user.id} with role #{Current.user.role}")
    
    # User metrics
    total_users = User.count
    users_with_spotify = User.where.not(spotify_access_token: nil).count
    admin_users = User.where(role: :admin).count
    
    # User registration metrics
    user_registrations = user_registrations_by_month
    
    # Friendship metrics
    total_friendships = Friendship.count
    accepted_friendships = Friendship.where(status: :accepted).count
    pending_friendships = Friendship.where(status: :pending).count
    
    # Login metrics - last 30 days
    login_data = logins_by_day(30)
    
    # Daily active users - last 30 days
    daily_active_users = daily_active_users_by_day(30)
    
    render json: {
      user_metrics: {
        total_users: total_users,
        users_with_spotify: users_with_spotify,
        admin_users: admin_users,
        spotify_connection_rate: (users_with_spotify.to_f / total_users * 100).round(2)
      },
      user_registrations: user_registrations,
      friendship_metrics: {
        total_friendships: total_friendships,
        accepted_friendships: accepted_friendships,
        pending_friendships: pending_friendships,
        acceptance_rate: total_friendships > 0 ? (accepted_friendships.to_f / total_friendships * 100).round(2) : 0
      },
      login_metrics: login_data,
      daily_active_users: daily_active_users
    }
  end
  
  private
  
  def require_admin
    Rails.logger.info("Checking admin role for user #{Current.user.id}: role=#{Current.user.role}, admin?=#{Current.user.admin?}")
    
    unless Current.user&.admin?
      Rails.logger.warn("Unauthorized admin access attempt by user #{Current.user.id} with role #{Current.user.role}")
      render json: { error: "Unauthorized. Admin access required." }, status: :unauthorized
    end
  end
  
  def user_registrations_by_month
    # Get user registrations by month for the last 12 months
    end_date = Date.today
    start_date = end_date - 11.months
    
    # Create a hash with all months initialized to 0
    months = {}
    (0..11).each do |i|
      month = (end_date - i.months).beginning_of_month
      months[month.strftime("%b %Y")] = 0
    end
    
    # Count users created in each month
    User.where(created_at: start_date.beginning_of_month..end_date.end_of_month)
        .group("DATE_TRUNC('month', created_at)")
        .count
        .each do |date, count|
          month_str = date.strftime("%b %Y")
          months[month_str] = count if months.key?(month_str)
        end
    
    # Convert to array of objects for the frontend
    months.map { |month, count| { name: month, value: count } }.reverse
  end
  
  def logins_by_day(days = 30)
    end_date = Date.today
    start_date = end_date - (days - 1).days
    
    # Create a hash with all days initialized to 0
    daily_logins = {}
    (0...days).each do |i|
      day = (start_date + i.days)
      daily_logins[day.strftime("%b %d")] = 0
    end
    
    # Count sessions created each day
    Session.where(created_at: start_date.beginning_of_day..end_date.end_of_day)
           .group("DATE_TRUNC('day', created_at)")
           .count
           .each do |date, count|
             day_str = date.strftime("%b %d")
             daily_logins[day_str] = count if daily_logins.key?(day_str)
           end
    
    # Convert to array of objects for the frontend
    daily_logins.map { |day, count| { name: day, value: count } }
  end
  
  def daily_active_users_by_day(days = 30)
    end_date = Date.today
    start_date = end_date - (days - 1).days
    
    # Create a hash with all days initialized to 0
    daily_users = {}
    (0...days).each do |i|
      day = (start_date + i.days)
      daily_users[day.strftime("%b %d")] = 0
    end
    
    # Count unique users with sessions each day
    Session.where(created_at: start_date.beginning_of_day..end_date.end_of_day)
           .group("DATE_TRUNC('day', created_at)")
           .select("DATE_TRUNC('day', created_at) as day, COUNT(DISTINCT user_id) as count")
           .each do |record|
             day_str = record.day.strftime("%b %d")
             daily_users[day_str] = record.count if daily_users.key?(day_str)
           end
    
    # Convert to array of objects for the frontend
    daily_users.map { |day, count| { name: day, value: count } }
  end
end
