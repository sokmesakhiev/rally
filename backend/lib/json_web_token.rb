module JsonWebToken
  SECRET_KEY = ENV.fetch("JWT_SECRET").presence || Rails.application.secret_key_base
  ALGORITHM  = "HS256"
  EXPIRY     = 30.days

  def self.encode(payload, exp = EXPIRY.from_now)
    payload[:exp] = exp.to_i
    JWT.encode(payload, SECRET_KEY, ALGORITHM)
  end

  def self.decode(token)
    decoded = JWT.decode(token, SECRET_KEY, true, { algorithm: ALGORITHM })[0]
    HashWithIndifferentAccess.new(decoded)
  rescue JWT::DecodeError => e
    raise JWT::DecodeError, e.message
  end
end
