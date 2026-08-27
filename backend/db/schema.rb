# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_28_000000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "admin_actions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action", null: false
    t.uuid "admin_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.uuid "target_id", null: false
    t.string "target_type", null: false
    t.index ["action"], name: "index_admin_actions_on_action"
    t.index ["admin_id"], name: "index_admin_actions_on_admin_id"
    t.index ["target_type", "target_id"], name: "index_admin_actions_on_target_type_and_target_id"
  end

  create_table "certificates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "file_url"
    t.uuid "registration_id", null: false
    t.datetime "updated_at", null: false
    t.index ["registration_id"], name: "index_certificates_on_registration_id", unique: true
  end

  create_table "event_activities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action", null: false
    t.uuid "actor_id", null: false
    t.datetime "created_at", null: false
    t.uuid "event_id", null: false
    t.jsonb "metadata", default: {}, null: false
    t.index ["action"], name: "index_event_activities_on_action"
    t.index ["actor_id"], name: "index_event_activities_on_actor_id"
    t.index ["event_id"], name: "index_event_activities_on_event_id"
  end

  create_table "event_invitations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.uuid "event_id", null: false
    t.datetime "expires_at", null: false
    t.uuid "invited_by_id", null: false
    t.datetime "revoked_at"
    t.string "role", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_event_invitations_on_email"
    t.index ["event_id", "email"], name: "index_event_invitations_on_event_and_email_pending", unique: true, where: "((accepted_at IS NULL) AND (revoked_at IS NULL))"
    t.index ["event_id"], name: "index_event_invitations_on_event_id"
    t.index ["token"], name: "index_event_invitations_on_token", unique: true
  end

  create_table "event_memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "accepted_at", null: false
    t.datetime "created_at", null: false
    t.uuid "event_id", null: false
    t.uuid "invited_by_id"
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["event_id", "user_id"], name: "index_event_memberships_on_event_id_and_user_id", unique: true
    t.index ["role"], name: "index_event_memberships_on_role"
    t.index ["user_id"], name: "index_event_memberships_on_user_id"
  end

  create_table "event_plan_payments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "abapay_deeplink"
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.uuid "event_id", null: false
    t.datetime "expires_at"
    t.datetime "paid_at"
    t.string "plan", null: false
    t.string "provider", default: "aba_payway", null: false
    t.text "qr_string"
    t.jsonb "raw_response", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.string "tran_id", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["event_id", "status"], name: "index_event_plan_payments_on_event_id_and_status"
    t.index ["event_id"], name: "index_event_plan_payments_on_event_id"
    t.index ["tran_id"], name: "index_event_plan_payments_on_tran_id", unique: true
  end

  create_table "event_types", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "capacity"
    t.datetime "created_at", null: false
    t.text "description"
    t.uuid "event_id", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.integer "price_cents"
    t.datetime "updated_at", null: false
    t.index ["event_id", "position"], name: "index_event_types_on_event_id_and_position"
    t.index ["event_id"], name: "index_event_types_on_event_id"
  end

  create_table "events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "banner_url"
    t.string "brand_color", default: "#6366f1", null: false
    t.integer "capacity"
    t.string "category", default: "other", null: false
    t.string "certificate_template_url"
    t.datetime "created_at", null: false
    t.uuid "creator_id", null: false
    t.string "currency", default: "usd", null: false
    t.datetime "deleted_at"
    t.text "description"
    t.datetime "end_at"
    t.string "freeze_reason"
    t.datetime "frozen_at"
    t.boolean "is_published", default: false, null: false
    t.decimal "latitude", precision: 10, scale: 6
    t.string "location"
    t.string "logo_url"
    t.decimal "longitude", precision: 10, scale: 6
    t.string "plan"
    t.integer "price_cents", default: 0, null: false
    t.string "route_map_url"
    t.datetime "start_at", null: false
    t.uuid "survey_id"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_events_on_category"
    t.index ["creator_id"], name: "index_events_on_creator_id"
    t.index ["deleted_at"], name: "index_events_on_deleted_at"
    t.index ["frozen_at"], name: "index_events_on_frozen_at", where: "(frozen_at IS NOT NULL)"
    t.index ["is_published", "start_at"], name: "index_events_on_is_published_and_start_at"
    t.index ["is_published"], name: "index_events_on_is_published"
    t.index ["start_at"], name: "index_events_on_start_at"
    t.index ["survey_id"], name: "index_events_on_survey_id"
  end

  create_table "payments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "abapay_deeplink"
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.datetime "expires_at"
    t.datetime "paid_at"
    t.string "provider", default: "aba_payway", null: false
    t.text "qr_string"
    t.jsonb "raw_response", default: {}, null: false
    t.integer "refunded_amount_cents", default: 0, null: false
    t.uuid "registration_id", null: false
    t.string "status", default: "pending", null: false
    t.string "tran_id", null: false
    t.datetime "updated_at", null: false
    t.index ["registration_id", "status"], name: "index_payments_on_registration_id_and_status"
    t.index ["registration_id"], name: "index_payments_on_registration_id"
    t.index ["tran_id"], name: "index_payments_on_tran_id", unique: true
  end

  create_table "profiles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "avatar_url"
    t.datetime "created_at", null: false
    t.string "display_name"
    t.boolean "notify_event_details_changed", default: true, null: false
    t.boolean "notify_payment_received", default: true, null: false
    t.boolean "notify_promoted_from_waitlist", default: true, null: false
    t.boolean "notify_refund_issued", default: true, null: false
    t.text "payway_api_key"
    t.string "payway_merchant_id"
    t.text "payway_rsa_public_key"
    t.string "phone"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["phone"], name: "index_profiles_on_phone", unique: true, where: "(phone IS NOT NULL)"
    t.index ["user_id"], name: "index_profiles_on_user_id", unique: true
  end

  create_table "refunds", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.uuid "initiated_by_id", null: false
    t.uuid "payment_id", null: false
    t.jsonb "raw_response", default: {}, null: false
    t.text "reason"
    t.string "refund_method", default: "gateway", null: false
    t.datetime "refunded_at"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["initiated_by_id"], name: "index_refunds_on_initiated_by_id"
    t.index ["payment_id"], name: "index_refunds_on_payment_id"
  end

  create_table "registration_answers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "answer_options", default: [], null: false
    t.text "answer_text"
    t.datetime "created_at", null: false
    t.uuid "registration_id", null: false
    t.uuid "survey_question_id", null: false
    t.datetime "updated_at", null: false
    t.index ["registration_id", "survey_question_id"], name: "index_reg_answers_on_reg_and_question", unique: true
    t.index ["registration_id"], name: "index_registration_answers_on_registration_id"
    t.index ["survey_question_id"], name: "index_registration_answers_on_survey_question_id"
  end

  create_table "registration_event_types", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "event_type_id", null: false
    t.uuid "registration_id", null: false
    t.datetime "updated_at", null: false
    t.index ["event_type_id"], name: "index_registration_event_types_on_event_type_id"
    t.index ["registration_id", "event_type_id"], name: "index_reg_event_types_on_reg_and_type", unique: true
    t.index ["registration_id"], name: "index_registration_event_types_on_registration_id"
  end

  create_table "registrations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "amount_owed_cents"
    t.integer "amount_paid_cents", default: 0, null: false
    t.datetime "checked_in_at"
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.uuid "event_id", null: false
    t.string "payment_status", default: "unpaid", null: false
    t.string "status", default: "confirmed", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["deleted_at"], name: "index_registrations_on_deleted_at"
    t.index ["event_id", "user_id"], name: "index_registrations_on_event_id_and_user_id", unique: true
    t.index ["event_id"], name: "index_registrations_on_event_id"
    t.index ["user_id"], name: "index_registrations_on_user_id"
  end

  create_table "results", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "finish_time_seconds"
    t.string "notes"
    t.uuid "registration_id", null: false
    t.datetime "updated_at", null: false
    t.index ["registration_id"], name: "index_results_on_registration_id", unique: true
  end

  create_table "survey_questions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "options", default: [], null: false
    t.integer "position", default: 0, null: false
    t.text "question_text", null: false
    t.string "question_type", default: "text", null: false
    t.boolean "required", default: false, null: false
    t.uuid "survey_id", null: false
    t.datetime "updated_at", null: false
    t.index ["survey_id", "position"], name: "index_survey_questions_on_survey_id_and_position"
    t.index ["survey_id"], name: "index_survey_questions_on_survey_id"
  end

  create_table "surveys", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "creator_id", null: false
    t.datetime "deleted_at"
    t.string "title", default: "Registration Survey", null: false
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_surveys_on_creator_id"
    t.index ["deleted_at"], name: "index_surveys_on_deleted_at"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.string "email", null: false
    t.boolean "email_auto_generated", default: false, null: false
    t.datetime "email_verification_sent_at"
    t.string "email_verification_token"
    t.datetime "email_verified_at"
    t.string "google_uid"
    t.string "password_digest", null: false
    t.datetime "password_reset_sent_at"
    t.string "password_reset_token"
    t.string "provider"
    t.datetime "suspended_at"
    t.string "suspension_reason"
    t.datetime "terms_accepted_at"
    t.string "terms_version"
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.uuid "verified_by_id"
    t.index ["admin"], name: "index_users_on_admin", where: "(admin = true)"
    t.index ["deleted_at"], name: "index_users_on_deleted_at", where: "(deleted_at IS NOT NULL)"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["email_verification_token"], name: "index_users_on_email_verification_token", unique: true
    t.index ["google_uid"], name: "index_users_on_google_uid", unique: true
    t.index ["password_reset_token"], name: "index_users_on_password_reset_token", unique: true
    t.index ["suspended_at"], name: "index_users_on_suspended_at", where: "(suspended_at IS NOT NULL)"
    t.index ["verified_at"], name: "index_users_on_verified_at", where: "(verified_at IS NOT NULL)"
  end

  create_table "waitlist_entries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.uuid "event_id", null: false
    t.jsonb "event_type_ids", default: [], null: false
    t.string "status", default: "waiting", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["deleted_at"], name: "index_waitlist_entries_on_deleted_at"
    t.index ["event_id", "created_at"], name: "index_waitlist_entries_on_event_and_created_at"
    t.index ["event_id", "user_id"], name: "index_waitlist_entries_on_event_and_user_when_waiting", unique: true, where: "((status)::text = 'waiting'::text)"
    t.index ["event_id"], name: "index_waitlist_entries_on_event_id"
    t.index ["user_id"], name: "index_waitlist_entries_on_user_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "admin_actions", "users", column: "admin_id"
  add_foreign_key "certificates", "registrations"
  add_foreign_key "event_activities", "events"
  add_foreign_key "event_activities", "users", column: "actor_id"
  add_foreign_key "event_invitations", "events"
  add_foreign_key "event_invitations", "users", column: "invited_by_id"
  add_foreign_key "event_memberships", "events"
  add_foreign_key "event_memberships", "users"
  add_foreign_key "event_memberships", "users", column: "invited_by_id"
  add_foreign_key "event_plan_payments", "events"
  add_foreign_key "event_plan_payments", "users"
  add_foreign_key "event_types", "events"
  add_foreign_key "events", "surveys"
  add_foreign_key "events", "users", column: "creator_id"
  add_foreign_key "payments", "registrations"
  add_foreign_key "profiles", "users"
  add_foreign_key "refunds", "payments"
  add_foreign_key "refunds", "users", column: "initiated_by_id"
  add_foreign_key "registration_answers", "registrations"
  add_foreign_key "registration_answers", "survey_questions"
  add_foreign_key "registration_event_types", "event_types"
  add_foreign_key "registration_event_types", "registrations"
  add_foreign_key "registrations", "events"
  add_foreign_key "registrations", "users"
  add_foreign_key "results", "registrations"
  add_foreign_key "survey_questions", "surveys"
  add_foreign_key "surveys", "users", column: "creator_id"
  add_foreign_key "waitlist_entries", "events"
  add_foreign_key "waitlist_entries", "users"
end
