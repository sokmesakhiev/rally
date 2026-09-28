# Phase 3, step one of two. **This migration must ship WITH the code that
# stopped maintaining `users.admin`, and the column drop must wait for a
# LATER deploy.** See the note at the bottom for why.
#
# `users_admin_matches_staff_role` required the boolean and the role to agree.
# It earned its keep while both were live: the reconcile callback was a
# `before_save` and therefore blind to `update_column`, `update_all` and raw
# SQL, so the database was the only layer that could see every writer.
#
# That callback is gone as of this deploy — `staff_role` is the single
# representation now, and nothing reads or writes the boolean. Leaving the
# constraint in place would therefore break the app rather than protect it:
# `User.create!(staff_role: "admin")` writes `admin = false` (the column
# default) alongside `staff_role = "admin"`, the two disagree, and **every
# attempt to create an admin fails**. The guard would outlive the thing it
# was guarding and take admin creation down with it.
#
# ── Why the column itself isn't dropped here ────────────────────────────────
#
# Migrations run unattended on container boot (`bin/docker-entrypoint` →
# `db:prepare`), and a deploy rolls tasks: old code keeps serving for a minute
# or two after the migration lands. Old code still runs the reconcile callback,
# which assigns `self[:admin]`. Drop the column in this same deploy and every
# user save on a not-yet-replaced task raises `UndefinedColumn` — including
# sign-ups and sign-ins.
#
# So: this deploy removes the constraint and the code that maintained the
# pair. A **separate, later** deploy runs `remove_column :users, :admin`. The
# two cannot be committed together, because `db:prepare` applies every pending
# migration at once and would collapse them back into one deploy.
class DropAdminStaffRoleConsistencyCheck < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :users,
                            "admin = (staff_role IS NOT DISTINCT FROM 'admin')",
                            name: "users_admin_matches_staff_role"
  end
end
