# frozen_string_literal: true

module Api
    module V1
        class BaseController < ApplicationController
            include ValidateParams
            include EventAuthorization
            include StaffAuthorization
        end
    end
end
