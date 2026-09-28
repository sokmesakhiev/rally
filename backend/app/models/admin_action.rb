# Queryable audit trail for the Rally staff moderation surface — see
# Api::V1::Admin::BaseController#log_admin_action, which writes one of these
# alongside its existing Rails.logger.info line (kept for log-aggregator
# visibility; this table is what makes the history actually queryable).
#
# Deliberately append-only: no updated_at (nothing should ever mutate a
# past action), and no model-level destroy guard is needed since nothing in
# the app calls #destroy on it.
class AdminAction < ApplicationRecord
  belongs_to :admin, class_name: "User"
  belongs_to :target, polymorphic: true

  validates :action, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :for_action, ->(action) { action.present? ? where(action: action) : all }
  scope :for_admin, ->(admin_id) { admin_id.present? ? where(admin_id: admin_id) : all }

  class << self
    # Single entry point for recording a moderation/admin action — writes
    # both the queryable row and a log line (for log-aggregator visibility,
    # same message shape as the old Rails.logger.info-only version). Called
    # from Api::V1::Admin::BaseController#log_admin_action (every action
    # reachable under the admin/ namespace) and directly from
    # Api::V1::RefundsController#create — the one admin-reachable action
    # outside that namespace, when an admin (not the organizer) issues a
    # refund.
    # `actor_role` is snapshotted here and never recomputed — D8 of
    # docs/staff-roles-design.md.
    #
    # Same reasoning as Message#sender_role, which is derived from position in
    # the thread rather than from the account's current status precisely so
    # that changing someone's status doesn't retroactively relabel months of
    # their history. Reading the role at display time would mean a support
    # agent promoted to admin appears to have always been one, and an audit
    # trail that reads differently after a promotion is not an audit trail.
    #
    # Lives in the existing `metadata` jsonb rather than a new column: nothing
    # queries by role yet, and a column that might never be filtered on is a
    # migration for a hypothesis.
    def log!(admin:, action:, target:, metadata: {})
      Rails.logger.info(
        "[admin] actor=#{admin.id} role=#{admin.staff_role} " \
        "action=#{action} target=#{target.class.name}##{target.id}"
      )
      create!(
        admin: admin,
        action: action,
        target: target,
        metadata: metadata.merge(actor_role: admin.staff_role)
      )
    end
  end
end
