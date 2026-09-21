// A stand-in for ABA PayWay, for the end-to-end suite only.
//
// Why a stub rather than ABA's sandbox (docs/e2e-testing-design.md, D2): the
// sandbox needs credentials, a network and ABA's uptime, and when its
// behaviour changes the suite goes red for a reason nobody on this side can
// fix. A contract test against the real sandbox is a separate, later idea —
// one test, run rarely, asserting their response shape still matches what
// this file imitates.
//
// **This is the one place the suite can lie to us.** Every shape below is
// copied from what backend/app/services/aba_payway/client.rb and
// ProcessAbaPaywayWebhookJob actually read. Two rules follow:
//
//   1. Keep it tiny. Every behaviour invented here is a behaviour the real
//      gateway might not have.
//   2. Don't "tidy" the status codes. generate-qr succeeds on `code: "0"`
//      and check-transaction succeeds on `code: "00"` — a single zero versus
//      two. That asymmetry is ABA's, it is what Rally checks for in
//      event_plan_payments_controller.rb and process_aba_payway_webhook_job.rb
//      respectively, and making it consistent here would either break every
//      payment journey or, worse, make them pass against a shape production
//      never sees.
//
// It does NOT verify the HMAC in `hash`. It holds no real API key and has
// nothing to verify against; signing is covered by backend unit specs.
//
// Run: node server.mjs        (PORT, default 3002)

import { createServer } from "node:http";
import { Buffer } from "node:buffer";

const PORT = Number(process.env.PORT ?? 3002);

// tran_id -> { amount, currency, callbackUrl, status }
//
// In memory, and that is the right scope: it is the gateway's view of one
// suite run. The suite's own reset truncates Rally's side; `POST /__reset`
// below clears this side, and the two are called together by the fixture.
const transactions = new Map();

const json = (res, status, body) => {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
};

const readBody = (req) =>
  new Promise((resolve, reject) => {
    let raw = "";
    req.on("data", (chunk) => {
      raw += chunk;
      // A request this size is a bug or an attack, and neither should be
      // absorbed silently into memory.
      if (raw.length > 1_000_000) reject(new Error("request body too large"));
    });
    req.on("end", () => {
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(
          new Error(`gateway received invalid JSON: ${raw.slice(0, 200)}`),
        );
      }
    });
    req.on("error", reject);
  });

// POST /api/payment-gateway/v1/payments/generate-qr
//
// Rally sends `callback_url` base64-encoded (Client#generate_qr does the
// encoding). Storing what Rally sent, rather than hardcoding an address for
// the Rails server, means the stub learns where to call back exactly as the
// real gateway does — and a journey that runs Rails on a different port keeps
// working with no change here.
const generateQr = (body) => {
  const tranId = body.tran_id;
  if (!tranId) {
    return { status: { code: "1", message: "tran_id is required" } };
  }

  const callbackUrl = body.callback_url
    ? Buffer.from(body.callback_url, "base64").toString("utf8")
    : null;

  transactions.set(tranId, {
    amount: body.amount,
    currency: body.currency,
    callbackUrl,
    status: "PENDING",
  });

  return {
    // One zero. See the header.
    status: { code: "0", message: "success" },
    qrString: `00020101021230${tranId}5802KH5909Rally E2E6304FAKE`,
    qrImage: "data:image/png;base64,iVBORw0KGgo=",
    abapay_deeplink: `abamobilebank://e2e/pay?tran_id=${tranId}`,
    app_store: "https://example.invalid/app-store",
    play_store: "https://example.invalid/play-store",
  };
};

// POST /api/payment-gateway/v1/payments/check-transaction-2
//
// This is the authoritative answer as far as Rally is concerned: the webhook
// is only a trigger, and ProcessAbaPaywayWebhookJob always comes back here
// before changing any state. So "did the money arrive" is decided by what
// this returns, which is what makes `POST /__pay` below sufficient to drive a
// payment journey.
const checkTransaction = (body) => {
  const tran = transactions.get(body.tran_id);
  if (!tran) {
    return { status: { code: "02", message: "transaction not found" } };
  }

  return {
    // Two zeros. See the header.
    status: { code: "00", message: "success" },
    data: {
      tran_id: body.tran_id,
      payment_status: tran.status === "APPROVED" ? "APPROVED" : "PENDING",
      payment_status_code: tran.status === "APPROVED" ? 0 : 1,
      total_amount: tran.amount,
      payment_currency: tran.currency,
      apv: tran.status === "APPROVED" ? "E2EAPV" : null,
    },
  };
};

// POST /__pay  { tran_id }   — the test's stand-in for a human paying.
//
// Marks the transaction approved and then fires Rally's own webhook at the
// callback URL Rally supplied, exactly as the real gateway would. That second
// half is the whole argument for a stub over a mock: Rally's webhook
// controller, its job, its check-transaction call, its idempotency and its
// state transition all execute for real. Only ABA's own servers are missing.
const pay = async (body) => {
  const tranId = body.tran_id;
  const tran = transactions.get(tranId);
  if (!tran) {
    return { ok: false, error: `unknown tran_id ${tranId}` };
  }

  tran.status = "APPROVED";

  if (!tran.callbackUrl) {
    return { ok: true, tran_id: tranId, webhook: "skipped (no callback_url)" };
  }

  // Deliberately awaited and reported rather than fired and forgotten. A
  // webhook that silently failed to deliver would show up as a payment
  // journey timing out on an assertion about the event going live — a
  // symptom several steps away from the cause.
  //
  // The try/catch is not defensive padding: without it, a Rails server that
  // isn't listening yet turns an unhandled promise rejection into a *dead
  // gateway process*, and every subsequent journey in the run fails with
  // ECONNREFUSED against this stub instead of against the thing that was
  // actually down. Report the delivery failure; stay up.
  try {
    const response = await fetch(tran.callbackUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      // `merchant_ref` is the field Rally's webhook controller reads first.
      body: JSON.stringify({
        merchant_ref: tranId,
        tran_id: tranId,
        status: 0,
      }),
    });

    return {
      ok: true,
      tran_id: tranId,
      webhook: { url: tran.callbackUrl, status: response.status },
    };
  } catch (error) {
    const reason = error?.cause?.message ?? error.message;
    console.error(
      `[fake-payway] webhook delivery to ${tran.callbackUrl} failed: ${reason}`,
    );
    return {
      ok: false,
      tran_id: tranId,
      error: `webhook delivery failed: ${reason}`,
      webhook: { url: tran.callbackUrl, delivered: false },
    };
  }
};

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);

  if (req.method === "GET" && url.pathname === "/__health") {
    return json(res, 200, { ok: true, transactions: transactions.size });
  }

  if (req.method !== "POST") {
    return json(res, 405, { error: `${req.method} not supported` });
  }

  let body;
  try {
    body = await readBody(req);
  } catch (error) {
    return json(res, 400, { error: error.message });
  }

  switch (url.pathname) {
    case "/api/payment-gateway/v1/payments/generate-qr":
      return json(res, 200, generateQr(body));

    case "/api/payment-gateway/v1/payments/check-transaction-2":
      return json(res, 200, checkTransaction(body));

    case "/__pay": {
      const result = await pay(body);
      return json(res, result.ok ? 200 : 404, result);
    }

    case "/__reset":
      transactions.clear();
      return json(res, 200, { ok: true });

    default:
      // Loud, because the alternative is a payment journey failing with a
      // JSON parse error four steps later. An unrecognised path means Rally
      // is calling something this stub doesn't imitate — which is exactly
      // the drift the design doc warns about.
      console.error(
        `[fake-payway] unhandled path ${req.method} ${url.pathname}`,
      );
      return json(res, 404, {
        error: `fake-payway has no route for ${url.pathname}`,
      });
  }
});

// Last line of defence. Anything that reaches here is a bug in this file, but
// the cost of letting it kill the process is every remaining journey in the
// run failing against a gateway that isn't there — a cascade that hides
// whichever test actually broke. Log it and keep serving.
process.on("unhandledRejection", (reason) => {
  console.error("[fake-payway] unhandled rejection:", reason);
});
process.on("uncaughtException", (error) => {
  console.error("[fake-payway] uncaught exception:", error);
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`[fake-payway] listening on http://127.0.0.1:${PORT}`);
});
