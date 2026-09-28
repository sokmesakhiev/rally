# Makes it impossible for `users.admin` and `users.staff_role` to disagree
# while both columns exist (Phase 0 → 3 of docs/staff-roles-design.md).
#
# `User#reconcile_staff_role_and_admin_flag` keeps them in step, but it is a
# `before_save` — so `update_column`, `update_all`, `insert_all`,
# `upsert_all` and raw SQL all route around it. Nothing in `app/` writes to
# `users` that way today, which is precisely the kind of guarantee that
# expires the next time somebody needs a fast backfill.
#
# A desync is not cosmetic. The two representations are read by different
# call sites that move across in different phases — `#admin?` reads the role,
# while `User.admins` and `Notifications::ModerationNotifier` still read the
# boolean — so they would disagree about who is staff. In one direction that
# silently keeps powers somebody was stripped of; in the other it locks an
# admin out. The database is the only layer that can see every writer.
#
# **`IS NOT DISTINCT FROM`, not `=`.** The obvious spelling,
# `admin = (staff_role = 'admin')`, is NULL for every non-staff row, and a
# CHECK that evaluates to NULL *passes* — so the constraint would quietly
# police admins only, which is the half that already works. `IS NOT DISTINCT
# FROM` is the NULL-safe comparison, giving false rather than NULL for a NULL
# `staff_role`, so the constraint covers all three cases: admin, other staff,
# and nobody.
#
# Validated against existing rows rather than added `NOT VALID` and validated
# later. That is the large-table pattern; this table is small, migrations here
# run unattended on container boot (`bin/docker-entrypoint`), and an atomic
# migration that either applies or doesn't is worth more in that setting than
# a shorter lock.
class AddAdminStaffRoleConsistencyCheck < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :users,
                         "admin = (staff_role IS NOT DISTINCT FROM 'admin')",
                         name: "users_admin_matches_staff_role"
  end
end
