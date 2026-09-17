import { assertEquals } from "jsr:@std/assert@1";
import { createHmac } from "node:crypto";
import { mapGatewayStatus, verifySignature, walletDebitMinorUnits } from "./logic.ts";

const SECRET = "test-webhook-secret";
const BODY = '{"payment_id":"pay_ABC123","status":"captured"}';

function sign(body: string, secret = SECRET): string {
  return createHmac("sha256", secret).update(body).digest("hex");
}

Deno.test("a correctly signed body is accepted", () => {
  assertEquals(verifySignature(BODY, sign(BODY), SECRET), true);
});

Deno.test("a body signed with the wrong secret is rejected", () => {
  assertEquals(verifySignature(BODY, sign(BODY, "not-the-secret"), SECRET), false);
});

Deno.test("a tampered body is rejected even with a once-valid signature", () => {
  const signature = sign(BODY);
  const tampered = BODY.replace("pay_ABC123", "pay_SOMEONE_ELSE");
  assertEquals(verifySignature(tampered, signature, SECRET), false);
});

Deno.test("a missing signature header is rejected, not skipped", () => {
  assertEquals(verifySignature(BODY, null, SECRET), false);
});

Deno.test("a truncated signature is rejected without throwing", () => {
  // timingSafeEqual throws on length mismatch, so this must be caught by the
  // length check rather than reaching it.
  assertEquals(verifySignature(BODY, sign(BODY).slice(0, 10), SECRET), false);
});

// If the secret is ever missing from the environment, every request must be
// rejected. The failure mode to avoid is an empty secret producing a stable
// HMAC that an attacker can compute for themselves.
Deno.test("an empty secret rejects everything, including a body signed with it", () => {
  assertEquals(verifySignature(BODY, sign(BODY, ""), ""), false);
});

Deno.test("captured means succeeded, refunded means refunded", () => {
  assertEquals(mapGatewayStatus("captured"), "succeeded");
  assertEquals(mapGatewayStatus("refunded"), "refunded");
});

Deno.test("anything unrecognised fails rather than succeeding", () => {
  for (const status of ["authorized", "pending", "SUCCEEDED", "", undefined, null]) {
    assertEquals(
      mapGatewayStatus(status as string),
      "failed",
      `"${status}" must not be treated as success`,
    );
  }
});

Deno.test("a wallet credit line yields its debit", () => {
  assertEquals(
    walletDebitMinorUnits([
      { label: "Consultation", amountMinorUnits: 59_900 },
      { label: "Wallet credit", amountMinorUnits: -25_000 },
    ]),
    -25_000,
  );
});

Deno.test("no wallet line means no debit", () => {
  assertEquals(walletDebitMinorUnits([{ label: "Consultation", amountMinorUnits: 59_900 }]), null);
  assertEquals(walletDebitMinorUnits([]), null);
  assertEquals(walletDebitMinorUnits(undefined), null);
});

// This function can only ever take money out. A positive amount on the wallet
// line — a bug, or a tampered quote — must not become a way to put money in.
Deno.test("a positive or zero wallet line never becomes a credit", () => {
  assertEquals(walletDebitMinorUnits([{ label: "Wallet credit", amountMinorUnits: 25_000 }]), null);
  assertEquals(walletDebitMinorUnits([{ label: "Wallet credit", amountMinorUnits: 0 }]), null);
});

Deno.test("a malformed wallet line is ignored rather than crashing the webhook", () => {
  assertEquals(walletDebitMinorUnits([{ label: "Wallet credit" }]), null);
  assertEquals(
    walletDebitMinorUnits([{ label: "Wallet credit", amountMinorUnits: NaN }]),
    null,
  );
});
