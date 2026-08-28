# Rally on RailsDev — Launch Story Series

Six posts, alternating **Business** and **Tech**, founder voice, ~100–200 words each. Suggested cadence: every other day for two weeks, starting next week. Swap the actual dates for whatever week you kick off.

---

## Post 1 — Business — "Why we built Rally"
**Suggested post date:** Week 1, Day 1 (Mon)

Every 5K, every century ride, every open-water swim starts the same way: someone with a spreadsheet, a Telegram group, and way too many DMs asking "did my payment go through?"

We kept meeting organizers running real events — running, cycling, swimming, triathlon — on tools that were never built for it. Generic form builders. Manual bank transfer screenshots. No way to see who's actually registered until race day.

So we built Rally: a registration platform for exactly this kind of event. Create an event, set your price and capacity per race category, let people register and pay, watch the list fill up in real time.

Nothing exotic. Just the thing organizers actually needed, built for how they actually work.

Next up: the hardest part of any of this was never the registration form. It was getting organizers paid. More on that Wednesday.

`#EventTech #BuildInPublic #RubyOnRails`

---

## Post 2 — Tech — "The stack, and why we didn't overbuild it"
**Suggested post date:** Week 1, Day 3 (Wed)

Rally is a Rails 8.1 API talking to a TanStack Start / React 19 frontend. No monolith, no server-rendered views on the backend — the frontend builds down to a static SPA shell and ships straight to S3 + CloudFront.

Auth is stateless JWT, not Devise sessions. `Authorization: Bearer <token>`, decode, done — because half of what we're protecting (browsing events) needs to stay public, and per-action gating is simpler than fighting a session-based auth stack that assumes everything's locked down by default.

Same philosophy on infra: Rails runs on ECS Fargate, background jobs run *inside* the same Puma process via Solid Queue rather than standing up a whole second worker service we don't need yet. No Kubernetes, no message queue cluster, no premature scaling story.

Boring technology, chosen on purpose. We'd rather ship the next feature than operate infrastructure sized for a scale we're not at.

`#RubyOnRails #TanStackStart #JWT`

---

## Post 3 — Business — "Getting organizers paid, not just registered"
**Suggested post date:** Week 1, Day 5 (Fri)

A registration form is easy. Getting an organizer their money is not — especially outside the US/EU-shaped default that most SaaS payment integrations assume.

We built Rally on ABA PayWay and KHQR from the start, because that's what our organizers and their attendees actually use. And we didn't stop at "Rally collects the money and pays you out later" — an organizer can connect their *own* PayWay merchant account, so registration payments go straight to them. Rally only sits in the middle for the platform fee, not for every attendee's payment.

That one decision changes the trust story completely. Organizers aren't waiting on us to release their funds. They're getting paid the way they already get paid, just with a registration system attached.

Tech side of this — how one payment gateway safely serves two very different kinds of transactions — is Monday's post.

`#Payments #KHQR #Fintech`

---

## Post 4 — Tech — "Two ledgers, one gateway"
**Suggested post date:** Week 2, Day 1 (Mon)

Rally has two completely different kinds of payment flowing through the same ABA PayWay client, and conflating them is an easy mistake to make.

`EventPlanPayment` is an organizer paying *us* to publish their event under a capacity tier. `Payment` is an attendee paying the *organizer* to register. Same gateway class, different credentials: plan payments always use Rally's platform account; registration payments use the organizer's own merchant credentials once they've connected one, and fall back to ours if they haven't.

Capacity enforcement lives in model validations, not database constraints — deliberately, because a full event needs to return a machine-readable `code: "full"` the frontend can react to (lock the UI, refetch capacity), not just a generic 500 or a silent constraint violation.

Small decisions like these are the difference between "it technically works" and "it holds up when three hundred people are registering for a race at once."

`#RubyOnRails #SystemDesign #Payments`

---

## Post 5 — Business — "Running an event is a team sport"
**Suggested post date:** Week 2, Day 3 (Wed)

Nobody runs a real event alone. There's the person who owns it, someone checking people in at the start line, someone managing results afterward, someone who just needs visibility without touching anything.

Rally treats that as a first-class idea, not an afterthought: invite people onto your event with a specific role — Manager, Check-in, Viewer — and each one sees exactly the tools they need, nothing more. Check-in staff get a scanner, not your payment settings.

And because a platform where anyone can spin up an event is also a platform someone will eventually try to abuse, we built a real moderation lever: if an event is reported and confirmed to be a scam or otherwise harmful, we can suspend it — hidden from public listings, locked from edits, and *not* something the organizer can quietly undo themselves. The owner gets emailed exactly why.

Trust has to work in both directions. This is how we back that up.

`#TrustAndSafety #ProductDesign #EventTech`

---

## Post 6 — Tech — "Shipping in two languages from day one"
**Suggested post date:** Week 2, Day 5 (Fri)

We didn't bolt on translation after the fact — Rally has been English *and* Khmer since early in the build. Every user-facing string in the app goes through i18next, namespaced per route or component, with both locale files kept in lockstep. If a key's missing in Khmer, that's a bug, not an edge case.

The one deliberate exception: the app always boots in English on first render, even for a Khmer-preferring visitor. Why — the production build is one static HTML shell, prerendered once and reused for every visitor, so there's no per-request way to know someone's stored language before the page paints. The real preference gets applied a beat later, client-side, once React hydrates. Small tradeoff, and one we made on purpose rather than fighting the deploy model we chose.

Building for two languages from the start was slower on day one. It meant we never had to go back and rip strings out of components later.

That's the series — more build notes to come as Rally grows.

`#i18n #RubyOnRails #TanStackStart`
