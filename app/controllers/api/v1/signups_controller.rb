class Api::V1::SignupsController < ApplicationController
  allow_unauthenticated_access only: [:create]

  def create
    signup = Signup.new(signup_params)
    
    if signup.save
      render json: { message: "Thank you for your interest! We'll notify you when we launch." }, status: :created
    else
      render json: { errors: signup.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def signup_params
    params.require(:signup).permit(:email)
  end
end
