#!/usr/bin/env node
// TEMPORARY — delete with Ticket D of support-chat-tickets.md.
//
// Ticket 0's go/no-go harness. Unit tests can prove the channel code is
// correct; only this can answer the questions that actually decide whether
// ActionCable is viable on this deployment:
//
//   1. Does the WebSocket upgrade survive the ALB?
//   2. Does the origin allowlist match what the real frontend origin sends?
//      (Getting this wrong refuses every connection in production while
//      development looks perfectly healthy — hence --origin, set explicitly.)
//   3. Does a broadcast published by one ECS task reach a subscriber attached
//      to the other? PingChannel echoes the responding host's name, so seeing
//      two distinct names proves Solid Cable is fanning out rather than each
//      task talking only to itself.
//   4. What does holding N connections cost — in task memory, and in REST
//      latency for everyone else?
//
// Credentials come from the environment, never argv, so they don't land in
// shell history or another user's `ps` output.
//
// PREREQUISITE: sign in as an **admin** account. PingChannel rejects everyone
// else, and this script will report "subscription rejected" for every
// connection. (`User.find_by(email: ...).update!(admin: true)` from a console.)
//
// The ENABLE_PING_CHANNEL=true env var opens the channel to any authenticated
// user, but it's only worth the trouble for a load run needing several
// non-admin accounts — the cable-ticket throttle is keyed per user, so ~30
// connections per account is the ceiling. See the channel for why the env var
// is awkward to set on ECS.
//
// NOTE ON --connections: config/initializers/rack_attack.rb throttles
// POST /api/v1/cable/ticket to 30 per 5 minutes per user, and this script
// takes one ticket per connection. Asking for more than 30 from one account
// gets the excess back as `ticket 429`.
//
//   Setup:  npm install --prefix scripts
//   Run:    API_URL=https://api.example.com \
//           ORIGIN=https://app.example.com \
//           TOKEN=<jwt> \
//           node scripts/cable-smoke.mjs --connections 200 --seconds 60
//
// Instead of TOKEN you may pass EMAIL and PASSWORD and it will sign in first.
// Watch ECS task memory in CloudWatch while this runs, and hit a normal REST
// endpoint alongside it to see whether p95 moves.

import WebSocket from "ws";

const args = Object.fromEntries(
  process.argv.slice(2).flatMap((arg, i, all) =>
    arg.startsWith("--") ? [[arg.slice(2), all[i + 1]]] : []
  )
);

const API_URL = process.env.API_URL?.replace(/\/$/, "");
const ORIGIN = process.env.ORIGIN;
const CONNECTIONS = Number(args.connections ?? 50);
const SECONDS = Number(args.seconds ?? 30);

if (!API_URL || !ORIGIN) {
  console.error("API_URL and ORIGIN are required. See the header of this file.");
  process.exit(1);
}

const CABLE_URL = `${API_URL.replace(/^http/, "ws")}/cable`;
const IDENTIFIER = JSON.stringify({ channel: "PingChannel" });

async function getToken() {
  if (process.env.TOKEN) return process.env.TOKEN;

  const { EMAIL, PASSWORD } = process.env;
  if (!EMAIL || !PASSWORD) {
    console.error("Set TOKEN, or EMAIL and PASSWORD.");
    process.exit(1);
  }

  const res = await fetch(`${API_URL}/api/v1/auth/signin`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: EMAIL, password: PASSWORD }),
  });
  if (!res.ok) {
    console.error(`Sign-in failed: ${res.status} ${await res.text()}`);
    process.exit(1);
  }
  return (await res.json()).token;
}

// One ticket per connection: they are single-use by design, so this also
// exercises the issue/redeem path under the same concurrency as the sockets.
async function getTicket(token) {
  const res = await fetch(`${API_URL}/api/v1/cable/ticket`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!res.ok) throw new Error(`ticket ${res.status}`);
  return (await res.json()).ticket;
}

const stats = {
  connected: 0,
  rejected: 0,
  subscribed: 0,
  rtts: [],
  hosts: new Set(),
  // Sockets that received echoes published by more than one host. This, not
  // the global `hosts` set, is what actually proves cross-task fan-out: a
  // global count of 2 is equally consistent with each task talking only to
  // its own subscribers, which is the failure this run exists to detect.
  socketsSeeingBothTasks: 0,
  errors: new Map(),
};

const noteError = (why) => stats.errors.set(why, (stats.errors.get(why) ?? 0) + 1);

function openOne(ticket) {
  // Per-socket, because "did *this* connection hear from the other task" is
  // the question. Every connection subscribes to the same stream, so if
  // fan-out works each one should see echoes from both hosts.
  const hostsSeenHere = new Set();

  return new Promise((resolve) => {
    // `origin` is the entire point of using `ws` rather than Node's built-in
    // WebSocket, which gives no way to set it.
    const socket = new WebSocket(`${CABLE_URL}?ticket=${encodeURIComponent(ticket)}`, {
      origin: ORIGIN,
      headers: { "User-Agent": "rally-cable-smoke" },
    });

    socket.on("unexpected-response", (_req, res) => {
      // A 404 here almost always means the origin was refused: ActionCable
      // declines before it ever upgrades.
      noteError(`http ${res.statusCode}`);
      stats.rejected++;
      resolve(socket);
    });

    socket.on("error", (err) => {
      noteError(err.message);
      resolve(socket);
    });

    socket.on("open", () => {
      stats.connected++;
      resolve(socket);
    });

    socket.on("message", (raw) => {
      const msg = JSON.parse(raw.toString());

      if (msg.type === "welcome") {
        socket.send(JSON.stringify({ command: "subscribe", identifier: IDENTIFIER }));
        return;
      }
      if (msg.type === "confirm_subscription") {
        stats.subscribed++;
        return;
      }
      if (msg.type === "reject_subscription") {
        noteError("subscription rejected");
        return;
      }
      if (msg.message?.echoed_at) {
        stats.rtts.push(Date.now() - msg.message.sent_at);
        stats.hosts.add(msg.message.from);

        if (!hostsSeenHere.has(msg.message.from)) {
          hostsSeenHere.add(msg.message.from);
          if (hostsSeenHere.size === 2) stats.socketsSeeingBothTasks++;
        }
      }
    });
  });
}

function ping(socket) {
  if (socket.readyState !== WebSocket.OPEN) return;
  socket.send(
    JSON.stringify({
      command: "message",
      identifier: IDENTIFIER,
      data: JSON.stringify({ action: "echo", sent_at: Date.now() }),
    })
  );
}

const percentile = (sorted, p) =>
  sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))] : NaN;

const token = await getToken();
console.log(`Opening ${CONNECTIONS} connections to ${CABLE_URL} as ${ORIGIN} …`);

const sockets = [];
for (let i = 0; i < CONNECTIONS; i++) {
  try {
    sockets.push(await openOne(await getTicket(token)));
  } catch (err) {
    noteError(err.message);
  }
  // Paced rather than all-at-once: a thundering herd would measure the
  // handshake burst, not the steady-state cost of holding connections open.
  await new Promise((r) => setTimeout(r, 20));
}

console.log(`Connected ${stats.connected}/${CONNECTIONS}. Echoing for ${SECONDS}s …`);
const timer = setInterval(() => sockets.forEach(ping), 5000);
sockets.forEach(ping);

await new Promise((r) => setTimeout(r, SECONDS * 1000));
clearInterval(timer);

const sorted = stats.rtts.sort((a, b) => a - b);
console.log(`
  connected      ${stats.connected}/${CONNECTIONS}
  rejected       ${stats.rejected}
  subscribed     ${stats.subscribed}
  echoes         ${stats.rtts.length}
  rtt p50/p95    ${percentile(sorted, 50)}ms / ${percentile(sorted, 95)}ms
  hosts seen     ${[...stats.hosts].join(", ") || "none"}
  fan-out        ${
    stats.hosts.size < 2
      ? "INCONCLUSIVE — only one task published; rerun with more connections"
      : stats.socketsSeeingBothTasks > 0
        ? `OK — ${stats.socketsSeeingBothTasks} socket(s) received echoes from both tasks`
        : "FAILED — two tasks published, but no single socket heard both. " +
          "Solid Cable is not fanning out; each task is talking only to itself."
  }
  errors         ${
    stats.errors.size ? [...stats.errors].map(([k, v]) => `${k} x${v}`).join(", ") : "none"
  }
`);

sockets.forEach((s) => s.close());
process.exit(stats.connected === CONNECTIONS && stats.errors.size === 0 ? 0 : 1);
