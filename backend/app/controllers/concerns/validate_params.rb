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
      validate_params.params = request.params.except("format", "controller", "action")
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
      messages = schema_errors.messages

      error_body = {
        "success" => false,
        "message" => "Unprocessable Entity",
        "code" => 422
      }

      error_body["errors"] = messages.map { |message|
        message.meta[:code].presence || ErrorCodes::GENERAL_ERROR
      }.uniq

      # Which field failed, structured. Most dry-schema messages carry no
      # `meta[:code]`, so `errors` above collapses to ["general_error"] and
      # says nothing at all — this is the part a caller can actually act on,
      # and the part a frontend can use to mark the offending input.
      error_body["details"] = messages.map do |message|
        { "field" => field_path(message), "message" => message.text }
      end

      # Every other controller in this app returns { error: "<human text>",
      # code: "<optional machine code>" } (see e.g. RegistrationsController's
      # capacity errors), and src/lib/api-client.ts's fetch wrapper only ever
      # reads response.json.error / .code — it has no awareness of `errors`
      # (plural). Without this, a schema validation failure would surface to
      # the user as a bare "API error 422" instead of the real message.
      #
      # The field name is prefixed rather than left to `details` alone,
      # because `error` is the string that reaches a human. It used to be
      # just `messages.map(&:text)`, which produced bodies like
      # `"error": "must be a string"` — true, unactionable, and requiring a
      # read of the schema source to find out which of seventeen fields was
      # meant.
      error_body["error"] = error_body["details"].map { |detail|
        detail["field"].present? ? "#{detail['field']} #{detail['message']}" : detail["message"]
      }.join(", ")

      error_body
    end

    # "event.description", or "event.event_types_attributes.0.capacity" for a
    # failure inside a nested array.
    #
    # The wrapper key (`event`, `registration`) is deliberately *not* stripped.
    # It would read a little cleaner for the nested schemas, but not every
    # schema wraps — the query-param ones are flat — so stripping the first
    # segment would be a guess that silently mislabels a field in exactly the
    # schemas where it guessed wrong.
    def field_path(message)
      Array(message.path).join(".")
    end
  end
end
