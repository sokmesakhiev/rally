# frozen_string_literal: true

# Validates POST /api/v1/admin/users/:id/suspend.
#
# `reason` is optional but capped — it's stored on the user and shown back in
# the admin list, so it's free text that needs a bound. Not required, because
# an obvious spam account shouldn't need a paragraph written about it before it
# can be dealt with.
class AdminSuspendUserRequestSchema < ApplicationRequestSchema
  MAX_REASON_LENGTH = 500

  params do
    optional(:reason).maybe(:string, max_size?: MAX_REASON_LENGTH)
  end
end
