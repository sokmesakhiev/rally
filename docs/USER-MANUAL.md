# Rally — User Manual

Rally is an event registration platform for participation sports: running, cycling, swimming, triathlon, hiking, and general events. This manual covers everything the platform does today, organized by who's doing it.

**Contents**

1. [Concepts you need to know](#1-concepts-you-need-to-know)
2. [For participants](#2-for-participants)
3. [For organizers](#3-for-organizers)
4. [For event team members](#4-for-event-team-members)
5. [For Rally staff (admin)](#5-for-rally-staff-admin)
6. [Email notifications reference](#6-email-notifications-reference)
7. [Languages & accessibility](#7-languages--accessibility)

---

## 1. Concepts you need to know

| Term | What it means |
|---|---|
| **Event** | A single occasion people register for. Has a date, location, category, price, and capacity. |
| **Event type** | An optional sub-race within an event — "5K", "10K", "Half Marathon". Each can carry its own price and capacity, overriding the event's. |
| **Registration** | One person's signup for one event, optionally tied to specific event types. |
| **Plan** | The capacity tier an organizer publishes under. Determines the maximum registrations allowed and what the organizer pays Rally. |
| **Survey** | An optional set of custom questions attached to an event (t-shirt size, emergency contact, etc.), answered at registration. |
| **Waitlist** | Where people land when an event or event type is full. Promoted automatically when a spot opens. |
| **Member / role** | Someone the organizer has invited to help run the event, with a specific permission level. |

### Pricing plans

Organizers pay Rally once, per event, to publish it. The plan sets the ceiling on total registrations.

| Plan | Capacity | Price |
|---|---|---|
| Free | 20 | Free |
| Small | 200 | $100.00 |
| Medium | 1,000 | $300.00 |
| Large | 10,000 | $1,000.00 |
| Extra Large | 30,000 | $2,000.00 |

The Free tier publishes immediately with no payment step. Paid tiers publish once payment clears.

> **Note:** If your event has event types with their own capacities, the plan must cover their combined total. Rally rejects publishing under a plan too small for the event types you've defined, before any payment is taken.

---

## 2. For participants

### Browsing and finding events

The public events page lists all published, upcoming events. No account needed to browse. Each event page shows the date, location, category, price, remaining capacity, description, and the organizer's branding.

If the organizer set a location with the map picker, you'll see a "View on map" link that opens Google Maps.

### Registering for an event

You can register **with or without an account**.

**As a guest:** Provide a name plus either an email address **or a phone number** — phone alone is enough. Rally attaches your registration to an account behind the scenes; if you've registered before with the same email or phone, it reuses that same account so your history stays together. Guest registration never logs you in and never asks you to invent a password.

**With an account:** Sign up with email and password, or use *Sign in with Google*. Your details prefill and all your registrations appear in one dashboard.

If the event has multiple event types, you pick which one(s) you're entering. If the organizer attached a survey, you answer those questions as part of registering.

### Paying

For paid events, Rally generates an **ABA PayWay KHQR code**. Scan it with your banking app and pay. The page watches for confirmation and updates automatically once the payment clears — you don't need to refresh or send a screenshot to anyone.

Payment confirmation also arrives by email (if you gave a real email address).

### Joining a waitlist

If the event or your chosen event type is full, you can join the waitlist instead. When someone cancels or is removed, Rally promotes the next person on the list automatically and emails them.

### Your ticket and check-in

Each confirmed registration gets a QR code — this is your ticket. On event day the organizer scans it (or looks you up by name) to check you in.

### After the event

- **Results.** If the organizer records finish times, you can see your result and the event leaderboard.
- **Certificates.** If the organizer uploaded a certificate template, Rally generates a personalized PDF certificate for confirmed, paid participants once the event has ended.

### Managing your account

From your profile you can update your display name and avatar, change your password or email address, set notification preferences, and delete your account. Deleting anonymizes your personal data rather than destroying event history.

**Notification preferences** let you opt out of specific categories. Some emails are never opt-out-able — payment confirmations, and notices about decisions affecting your own event.

---

## 3. For organizers

### Creating an event

From your dashboard, choose *Create event* and fill in:

- **Title, category, description**
- **Date and time** (start, optional end)
- **Location** — free-text, or use the Google Maps picker to search and drop a pin. The picker is optional; typed addresses work fine.
- **Route map link** — optional, for point-to-point events (e.g. a Google My Maps URL)
- **Price and capacity**
- **Event types** — optional sub-races, each with its own name, price, and capacity

Your event starts as a **draft**: not visible publicly, fully editable.

> **Paid events require a verified organizer account.** Rally staff verify organizers before they can charge for registrations. Free events need no verification. This is a fraud-prevention measure — contact Rally staff to get verified.

### Branding

Upload a banner image and a logo, and set a brand color. These appear on your public event page.

### Surveys

Build a custom questionnaire and attach it to your event. Question types support single and multiple choice with defined options. Answers are collected at registration and visible to you in the Survey Responses tab. Surveys are reusable across events.

### Publishing

Pick a plan that covers your expected capacity, then publish.

- **Free plan:** publishes immediately.
- **Paid plans:** Rally generates a KHQR code; the event goes live once your payment clears.

You can unpublish your own event at any time — it disappears from public listings and stops accepting registrations, but keeps all existing data.

### Getting paid: connecting your own PayWay account

By default, registration payments run through Rally's payment account. **Better: connect your own ABA PayWay merchant credentials** in Profile → Payment settings. Once connected, attendee registration payments go directly to your merchant account, not through Rally.

Your API key is stored encrypted and never shown back to you in full — only a masked version.

> Publishing-plan payments (what you pay Rally) always run through Rally's own account regardless of this setting. Only attendee registration payments are affected.

### Managing participants

The Participants tab shows everyone registered, with their status, chosen event types, payment state, and survey answers.

You can:

- **Edit a registration** — correct details, adjust event type, adjust amount owed
- **Remove a participant** — frees their spot and triggers waitlist promotion
- **Export to CSV** — full participant list for offline use
- **Issue a refund** — for paid registrations, through PayWay

### Check-in on event day

The Check-in tab gives you a scanner. Scan a participant's ticket QR to check them in, or search by name and tap them in manually. Check-ins can be undone if you make a mistake.

This is the tab you'd hand to a volunteer at the start line — see roles below.

### Results and leaderboards

For race-style events, record finish times either one at a time or by **importing a CSV** in bulk. Rally builds a leaderboard from the recorded results. Events that don't need timing (social rides, gatherings) simply never use this.

### Certificates

Upload an ODT certificate template with placeholder fields. Once the event has ended, Rally generates a personalized PDF for each confirmed, paid participant.

### Activity log

Every significant action on your event is recorded: price changes, date changes, participant removals, member invitations and role changes, people joining the team. Useful when several people share management of an event and you need to know who changed what.

### Notifying participants of changes

When you change an event's price, start date, or end date, Rally can email registered participants about it — respecting each participant's notification preferences.

---

## 4. For event team members

Running an event is rarely a solo job. Invite people to help via **Members → Invite**, sending an email invitation to a specific role.

### Roles and what each can do

| Capability | Owner | Manager | Check-in | Viewer |
|---|:--:|:--:|:--:|:--:|
| View event details | ✅ | ✅ | ✅ | ✅ |
| View participants | ✅ | ✅ | ✅ | ✅ |
| View waitlist | ✅ | ✅ | — | ✅ |
| View survey responses | ✅ | ✅ | — | ✅ |
| View activity log | ✅ | ✅ | — | ✅ |
| Check participants in | ✅ | ✅ | ✅ | — |
| Edit event details | ✅ | ✅ | — | — |
| Manage results | ✅ | ✅ | — | — |
| Edit/remove registrations | ✅ | ✅ | — | — |
| Export participants | ✅ | ✅ | — | — |
| Issue refunds | ✅ | ✅ | — | — |
| Pay for / change plan | ✅ | — | — | — |
| Unpublish event | ✅ | — | — | — |
| Delete event | ✅ | — | — | — |
| Invite / manage members | ✅ | — | — | — |

**Check-in** is deliberately narrow — a volunteer at the start line sees the check-in scanner and participant list, and nothing else. No payment settings, no ability to edit anything.

Invitations are sent by email and accepted via a link. Any member can remove themselves (leave an event); only the owner can change someone's role or remove another person.

---

## 5. For Rally staff (admin)

The admin console is available to accounts with the admin flag, granted from the server console only — there is no in-app way to promote someone to admin. Non-admins who navigate to the admin URL get a *not found* response; the surface doesn't advertise itself.

### User moderation

- **Suspend an account** — signs them out immediately and takes down all their published events. Their own registrations for other people's events are unaffected. Reason optional, recorded internally.
- **Restore an account** — reverses a suspension.
- **Verify / unverify an organizer** — verification gates the ability to create paid events. Removing verification doesn't affect already-published paid events.

### Event moderation

Two levers, deliberately different in strength:

- **Unpublish** — takes the event off public listings. The organizer can undo this themselves by republishing.
- **Suspend** — the strong lever, for scams and harmful content. The event is hidden, and the organizer is locked out of editing, publishing, or managing it in any way. **Only Rally staff can reverse it.** A reason is required and is emailed to the organizer verbatim, along with a link to the event and its ID so they can appeal.

While suspended, the organizer and their team retain read-only access — they can still see the event and why it was suspended, but cannot change anything.

- **Delete an event** — permanent. Refuses to hard-delete events with paid registrations.

### Reports and audit trail

The admin console includes platform reports and a queryable, append-only **audit trail** of every admin action: who did what, to whom, and when. Admin actions cannot be edited or deleted after the fact.

---

## 6. Email notifications reference

| Email | Sent to | When | Opt-out? |
|---|---|---|---|
| Email verification | New user | On signup | No |
| Password reset | User | On request | No |
| Event created | Organizer | Event created | No |
| Registration confirmation | Participant | On registering | No |
| Payment received | Participant | Payment clears | No |
| Refund issued | Participant | Refund processed | No |
| Promoted from waitlist | Participant | A spot opens | No |
| Event details changed | Participants | Organizer changes price/dates | **Yes** |
| Team invitation | Invitee | Organizer invites them | No |
| Event suspended | Organizer | Rally staff suspend the event | No |

---

## 7. Languages & accessibility

Rally ships in **English and Khmer**. Switch languages with the globe icon in the header; your choice is remembered.

The page always loads in English first and applies your saved language a moment later — a deliberate tradeoff of the static-hosting architecture, not a bug.

**Guest-friendly by design:** registration works with a phone number alone, no email and no password required, reflecting how people in Cambodia actually communicate.

---

*This manual describes Rally as built. For deployment and operational documentation, see the repository's `CLAUDE.md` and `infrastructure/`.*
