# frozen_string_literal: true

class ApplicationRequestSchema < Dry::Validation::Contract
  option :request

  INITIAL_CURSOR = 1
  RECORD_LIMIT = 50

  delegate :success?, :errors, to: :result

  register_macro(:validate_email) do
    unless value.match?(URI::MailTo::EMAIL_REGEXP)
      key.failure(
        text: I18n.t('dry_validation.email.invalid_format'),
        code: ErrorCodes::EMAIL_FORMAT_IS_INVALID
      )
    end
  end

  def output
    result.to_h
  end

  private

  def result
    @result ||= call(input_params)
  end

  def input_params
    request.params
  end
end
