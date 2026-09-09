require "rails_helper"

RSpec.describe Notifications::RegistrationNotifier do
  let(:participant) { create(:user) }
  let(:event) { create(:event, title: "Angkor Half Marathon") }
  let(:registration) { create(:registration, event: event, user: participant) }

  describe "#payment_received" do
    it "records an in-app notification the bell can count" do
      expect { described_class.payment_received(registration) }
        .to change(Notification, :count).by(1)

      notification = Notification.last
      expect(notification.user).to eq(participant)
      expect(notification.event).to eq(event)
      expect(notification.kind).to eq("payment_received")
      expect(notification.body).to include("Angkor Half Marathon")
      expect(notification).not_to be_read
    end

    it "enqueues a push" do
      expect { described_class.payment_received(registration) }
        .to have_enqueued_job(SendPushNotificationJob)
    end
  end

  # The one place this deliberately diverges from the mailers: notify_* means
  # "don't interrupt me", and the bell isn't an interruption. Suppressing the
  # in-app row would leave someone who muted payment emails with no way at all
  # to discover their payment cleared.
  describe "when the user has muted this notification type" do
    # User#after_create already builds the profile, so update it rather than
    # creating a second one.
    before { participant.profile.update!(notify_payment_received: false) }

    it "still records the in-app notification" do
      expect { described_class.payment_received(registration) }
        .to change(Notification, :count).by(1)
    end

    it "does not enqueue a push" do
      expect { described_class.payment_received(registration) }
        .not_to have_enqueued_job(SendPushNotificationJob)
    end
  end

  # No notify_confirmation column exists — the confirmation email is
  # unconditional too, being transactional.
  describe "#confirmation" do
    it "pushes even with every other preference off" do
      participant.profile.update!(
        notify_payment_received: false,
        notify_promoted_from_waitlist: false,
        notify_refund_issued: false,
        notify_event_details_changed: false
      )

      expect { described_class.confirmation(registration) }
        .to have_enqueued_job(SendPushNotificationJob)
    end
  end

  describe "every kind it can produce" do
    it "is declared in Notification::KINDS" do
      %i[confirmation payment_received promoted_from_waitlist refund_issued
         event_details_changed].each do |method|
        Notification.delete_all
        described_class.public_send(method, registration)

        expect(Notification.last.kind).to be_in(Notification::KINDS),
          "#{method} produced an undeclared kind"
      end
    end
  end

  # A payment that succeeded and then 500s because a bell row couldn't be
  # written would be a far worse bug than a missing badge.
  describe "when recording fails" do
    before do
      allow(Notification).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")
    end

    it "does not raise" do
      expect { described_class.payment_received(registration) }.not_to raise_error
    end

    # Block form, not `expect(Job).to have_been_enqueued`: the past-tense
    # matcher counts everything enqueued across the whole example group, and
    # earlier examples here enqueue their own pushes.
    it "still sends the push" do
      expect { described_class.payment_received(registration) }
        .to have_enqueued_job(SendPushNotificationJob)
    end
  end
end
