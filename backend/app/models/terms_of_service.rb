# One place both the signup flow and any future re-acceptance gate read
# from — see event-freeze-and-terms-tickets.md's Ticket F. Versioned rather
# than a plain boolean on User (`terms_accepted_at`/`terms_version`) so that
# a future ToS update can require existing users to re-accept without
# conflating "never agreed to anything" with "agreed to an old version".
#
# Bump CURRENT_VERSION whenever the actual Terms of Service / Privacy Policy
# copy changes in a way that needs fresh acceptance. Retroactively enforcing
# re-acceptance on existing users is deliberately out of scope for Ticket F —
# see the scoping doc's "Open questions".
module TermsOfService
  CURRENT_VERSION = "2026-08-27"
end
