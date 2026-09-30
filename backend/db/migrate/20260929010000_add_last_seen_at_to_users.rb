# frozen_string_literal: true

# "Last seen", not "last signed in".
#
# Auth is stateless JWT with a 30-day lifetime, so the moment somebody exchanges
# a password for a token says almost nothing about whether the account is in
# use — an organizer running events every day can have signed in once, a month
# ago. The question the console is actually asking is "is this account active",
# and only the request path can answer it.
#
# No index. Nothing filters or sorts on this column: it is read one row at a
# time, by primary key, from the user detail sheet. An index would be pure
# write cost on a column that is written far more often than it is read.
class AddLastSeenAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :last_seen_at, :datetime
  end
end
