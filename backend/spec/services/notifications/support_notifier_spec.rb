require "rails_helper"

RSpec.describe Notifications::SupportNotifier do
  let(:participant) { create(:user) }
  let(:admin) { create(:user, admin: true) }
  let(:conversation) { create(:conversation, user: participant) }

  def staff_reply(body: "Looking into it now")
    create(:message, conversation: conversation, sender: admin, body: body)
  end

  describe "a staff reply" do
    it "records an in-app notification for the participant" do
      expect { described_class.staff_replied(staff_reply) }
        .to change(Notification, :count).by(1)

      notification = Notification.last
      expect(notification.user).to eq(participant)
      expect(notification.kind).to eq("support_reply")
      expect(notification).not_to be_read
    end

    it "pushes" do
      expect { described_class.staff_replied(staff_reply) }
        .to have_enqueued_job(SendPushNotificationJob)
    end

    # Scheduling mechanics are ActiveJob's business; what matters here is that
    # the fallback is queued for *this* message. Whether it actually sends is
    # the job's own decision and is covered in its spec.
    it "queues the email fallback for this reply" do
      message = staff_reply

      expect { described_class.staff_replied(message) }
        .to have_enqueued_job(SupportReplyFallbackEmailJob).with(message.id)
    end

    # Unlike most kinds there is no notify_support_reply column, deliberately:
    # a reply is the answer to a question this person asked, which puts it with
    # the transactional confirmation rather than the mutable announcements.
    it "pushes even with every other notification preference off" do
      participant.profile.update!(
        notify_payment_received: false,
        notify_promoted_from_waitlist: false,
        notify_refund_issued: false,
        notify_event_details_changed: false,
      )

      expect { described_class.staff_replied(staff_reply) }
        .to have_enqueued_job(SendPushNotificationJob)
    end

    it "truncates a long reply rather than storing the whole thing" do
      described_class.staff_replied(staff_reply(body: "x" * 500))

      expect(Notification.last.body.length).to be <= 140
    end
  end

  # The participant just typed it, and staff have the console's own badge.
  describe "anything that isn't a staff reply" do
    it "ignores a participant's own message" do
      message = create(:message, conversation: conversation, sender: participant)

      expect { described_class.staff_replied(message) }.not_to change(Notification, :count)
    end

    # A push saying "your conversation was closed" is noise, not news — the
    # thread's state is visible the moment they next look.
    it "ignores the system resolve notice" do
      Conversations::Resolve.call(conversation: conversation)
      notice = conversation.messages.last
      expect(notice.sender_role).to eq(Message::SYSTEM)

      expect { described_class.staff_replied(notice) }.not_to change(Notification, :count)
    end
  end

  # PostMessage calls this from inside conversation.with_lock, so a bare rescue
  # would leave that transaction aborted and take the reply down with it.
  describe "when recording fails" do
    before do
      allow(Notification).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")
    end

    it "does not raise" do
      expect { described_class.staff_replied(staff_reply) }.not_to raise_error
    end

    it "still pushes" do
      expect { described_class.staff_replied(staff_reply) }
        .to have_enqueued_job(SendPushNotificationJob)
    end
  end
end
