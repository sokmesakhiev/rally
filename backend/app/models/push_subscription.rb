# A browser that has granted notification permission and subscribed to web
# push. One row per browser per device, not per user — see the migration.
#
# registration-engagement-tickets.md, push notifications ticket.
class PushSubscription < ApplicationRecord
  belongs_to :user

  validates :endpoint, presence: true, uniqueness: true
  validates :p256dh_key, presence: true
  validates :auth_key, presence: true

  # Everything not yet rejected by the push service. All sending goes through
  # this scope — an expired row is history, not a delivery target.
  scope :active, -> { where(expired_at: nil) }
  scope :expired, -> { where.not(expired_at: nil) }

  def expired?
    expired_at.present?
  end

  # Browsers silently rotate or drop subscriptions — a reinstall, a cleared
  # site data, a long-idle device. The push service then answers 404 or 410,
  # which is not an error to retry but a fact to record: this endpoint is
  # never coming back.
  def expire!
    update!(expired_at: Time.current) unless expired?
  end

  # The shape the web-push protocol wants. Kept here rather than in the
  # adapter so the column names are free to change without the sending code
  # caring.
  def to_push_params
    {
      endpoint: endpoint,
      p256dh: p256dh_key,
      auth: auth_key
    }
  end
end
