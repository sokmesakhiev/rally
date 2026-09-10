require "rails_helper"

RSpec.describe SupportReplyFallbackEmailJob, type: :job do
  let(:participant) { create(:user) }
  let(:admin) { create(:user, admin: true) }
  let(:conversation) { create(:conversation, user: participant) }
  let(:reply) { create(:message, conversation: conversation, sender: admin, body: "Sorted for you") }

  it "emails a participant who never came back" do
    expect { described_class.perform_now(reply.id) }
      .to have_enqueued_job(ActionMailer::MailDeliveryJob)
  end

  # The whole point of the delay: someone reading in the panel should never get
  # an email about a message they're looking at.
  it "stays quiet once they've read it" do
    conversation.update!(participant_last_read_at: reply.created_at + 1.second)

    expect { described_class.perform_now(reply.id) }
      .not_to have_enqueued_job(ActionMailer::MailDeliveryJob)
  end

  # A read stamp from *before* the reply doesn't count — they read the thread,
  # then this arrived.
  it "still emails when the read stamp predates the reply" do
    conversation.update!(participant_last_read_at: reply.created_at - 1.minute)

    expect { described_class.perform_now(reply.id) }
      .to have_enqueued_job(ActionMailer::MailDeliveryJob)
  end

  # Three replies in a row shouldn't mean three emails. The last one wins,
  # since it's the one whose fallback fires with the freshest information.
  it "defers to a newer staff reply rather than sending twice" do
    create(:message, conversation: conversation, sender: admin,
                     body: "One more thing", created_at: reply.created_at + 1.minute)

    expect { described_class.perform_now(reply.id) }
      .not_to have_enqueued_job(ActionMailer::MailDeliveryJob)
  end

  it "is not confused by the participant's own later message" do
    create(:message, conversation: conversation, sender: participant,
                     created_at: reply.created_at + 1.minute)

    expect { described_class.perform_now(reply.id) }
      .to have_enqueued_job(ActionMailer::MailDeliveryJob)
  end

  # Messages only disappear with the conversation, which only goes with the
  # account — so there's nobody left to email and retrying would never succeed.
  it "discards rather than retrying when the message is gone" do
    id = reply.id
    reply.destroy

    expect { described_class.perform_now(id) }.not_to raise_error
  end
end
