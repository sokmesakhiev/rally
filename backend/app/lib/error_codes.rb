# frozen_string_literal: true

# Machine-readable error codes returned alongside human-readable messages,
# so the frontend can branch on `code` instead of string-matching `message`
# (see ValidateParams#build_error_response). Other parts of the app already
# use this same idea with plain inline strings instead of constants here
# (RegistrationsController's "full", EventPlanPaymentsController's
# "plan_capacity_too_low") — this module exists only because
# ApplicationRequestSchema/ValidateParams reference ErrorCodes by name.
module ErrorCodes
  GENERAL_ERROR = "general_error"
  EMAIL_FORMAT_IS_INVALID = "email_format_is_invalid"
end
