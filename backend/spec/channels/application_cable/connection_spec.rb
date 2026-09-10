require "rails_helper"

RSpec.describe ApplicationCable::Connection, :with_cache, type: :channel do
  let(:user) { create(:user) }

  it "identifies the connection from a valid ticket" do
    connect "/cable?ticket=#{Cable::Ticket.issue(user)}"

    expect(connection.current_user).to eq(user)
  end

  it "refuses a connection with no ticket at all" do
    expect { connect "/cable" }.to have_rejected_connection
  end

  it "refuses an unknown ticket" do
    expect { connect "/cable?ticket=made-up" }.to have_rejected_connection
  end

  # The whole point of single use: a ticket captured in flight is spent.
  it "refuses a ticket that has already been redeemed" do
    ticket = Cable::Ticket.issue(user)
    Cable::Ticket.redeem(ticket)

    expect { connect "/cable?ticket=#{ticket}" }.to have_rejected_connection
  end

  it "refuses an expired ticket" do
    ticket = Cable::Ticket.issue(user)

    travel(Cable::Ticket::TTL + 1.second) do
      expect { connect "/cable?ticket=#{ticket}" }.to have_rejected_connection
    end
  end

  # Mirrors ApplicationController#authenticate_user!'s account-state gates. A
  # socket lives for hours, so letting a suspended account open one is worse
  # here than letting it make a single request.
  context "when the account is not in good standing" do
    it "refuses a suspended account" do
      ticket = Cable::Ticket.issue(user)
      user.update!(suspended_at: Time.current)

      expect { connect "/cable?ticket=#{ticket}" }.to have_rejected_connection
    end

    it "refuses a deleted account" do
      ticket = Cable::Ticket.issue(user)
      user.update!(deleted_at: Time.current)

      expect { connect "/cable?ticket=#{ticket}" }.to have_rejected_connection
    end
  end
end
