module RequestHelpers
  # POST /api/v1/auth/signup and return parsed JSON
  def signup(email: nil, password: "password123", display_name: nil)
    email ||= Faker::Internet.unique.email
    post "/api/v1/auth/signup", params: { email:, password:, display_name: }.compact,
                                as: :json
    JSON.parse(response.body)
  end

  # POST /api/v1/auth/signin and return the JWT token string
  def signin(user, password: "password123")
    post "/api/v1/auth/signin", params: { email: user.email, password: }, as: :json
    JSON.parse(response.body)["token"]
  end

  # Build an Authorization header hash
  def auth_headers(user, password: "password123")
    token = signin(user, password:)
    { "Authorization" => "Bearer #{token}" }
  end

  def json
    JSON.parse(response.body)
  end
end
