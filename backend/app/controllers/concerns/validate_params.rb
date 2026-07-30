# frozen_string_literal: true

module ValidateParams
  extend ActiveSupport::Concern

  included do
    # Note: this app is API-only (config.api_only = true, no sessions/flash
    # middleware, no HTML views) — there's deliberately no
    # validate_admin_params_with_schema/flash+redirect_to variant here. That
    # pattern belongs to a server-rendered app and would raise if called in
    # this one; every endpoint (including unauthenticated webhooks, which
    # have no "referer" to redirect to) renders JSON via the method below.
    def validate_params_with_schema(schema_type, schema_options: {}, &_block)
      validate_params = ActiveSupport::OrderedOptions.new
      validate_params.params = request.params.except('format', 'controller', 'action')
      schema = schema_type.new(
        request: validate_params,
        **schema_options
      )

      if schema.success?
        yield(schema.output)
      else
        # :unprocessable_entity, not :ok — api-client.ts's fetch wrapper
        # treats any non-2xx as a failure (throws ApiError) and only reads a
        # response body as the success shape otherwise. Returning 200 here
        # would make the frontend try to read a nonexistent `event` key out
        # of this error body instead of surfacing the validation error.
        render json: build_error_response(schema.errors), status: :unprocessable_entity
      end
    end

    def build_error_response(schema_errors)
      error_body = {
        'success' => false,
        'message' => 'Unprocessable Entity',
        'code' => 422
      }
      error_body['errors'] = schema_errors.messages.map do |message|
        message.meta[:code].presence || ErrorCodes::GENERAL_ERROR
      end
      error_body['errors'].uniq!

      # Every other controller in this app returns { error: "<human text>",
      # code: "<optional machine code>" } (see e.g. RegistrationsController's
      # capacity errors), and src/lib/api-client.ts's fetch wrapper only ever
      # reads response.json.error / .code — it has no awareness of `errors`
      # (plural). Without this, a schema validation failure would surface to
      # the user as a bare "API error 422" instead of the real message.
      error_body['error'] = schema_errors.messages.map(&:text).join(", ")

      error_body
    end
  end
end
