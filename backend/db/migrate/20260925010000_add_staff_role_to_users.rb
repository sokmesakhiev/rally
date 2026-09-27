# Phase 0 of docs/staff-roles-design.md.
#
# Adds the column and backfills it from `users.admin`. **Deliberately does not
# remove `admin`** — D2. The failure mode of getting this cutover wrong is
# that nobody can administer the platform, including the person who would fix
# it, so the boolean stays until Phase 3 and the rollback target is always a
# working console.
#
# After this runs, the two representations are kept in step by
# User#reconcile_staff_role_and_admin_flag. Nothing reads `staff_role` for an
# authorization decision yet except User#admin?, which this migration's
# backfill is what makes safe.
class AddStaffRoleToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :staff_role, :string

    # Partial, mirroring the existing `index_users_on_admin ... WHERE (admin
    # = true)`. Staff are a rounding error in this table; indexing the NULLs
    # would be indexing every ordinary participant.
    add_index :users, :staff_role, where: "staff_role IS NOT NULL",
              name: "index_users_on_staff_role"

    # Raw SQL, not User.update_all, and not a model iteration. By the time
    # this runs the model already carries the reconcile callback, and running
    # application callbacks inside a migration means the backfill depends on
    # whatever the model looks like the day someone replays it. The column is
    # the contract here, so write to the column.
    execute("UPDATE users SET staff_role = 'admin' WHERE admin = true")
  end

  def down
    remove_index :users, name: "index_users_on_staff_role"
    remove_column :users, :staff_role
  end
end
