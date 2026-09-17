// The parts of the payment webhook that decide things, separated from the
// parts that talk to Postgres.
//
// This handler is the only place a payment is ever marked succeeded, and it
// had never been executed — not in a test, not in CI, not anywhere. The
// Postgres calls genuinely need a database and the gateway callback genuinely
// needs a gateway, but the three decisions below need neither, and they are
// the ones that matter: whether to trust the caller at all, what a gateway
// status means, and how much money to take out of somebody's wallet.

import { createHmac, timingSafeEqual } from "node:crypto";

/// Whether this request really came from the gateway.
///
/// Compared in constant time, because a byte-by-byte comparison that returns
/// early leaks how much of a guessed signature was correct, and an attacker
/// who can measure that can forge one. The length check in front is not a
/// leak worth worrying about — signature length is fixed and public — but
/// `timingSafeEqual` throws on mismatched lengths, so it has to be there.
export function verifySignature(
  rawBody: string,
  signatureHeader: string | null,
  secret: string,
): boolean {
  if (!signatureHeader) return false;
  if (!secret) return false;
  const expected = createHmac("sha256", secret).update(rawBody).digest("hex");
  const expectedBuf = Buffer.from(expected, "utf8");
  const givenBuf = Buffer.from(signatureHeader, "utf8");
  if (expectedBuf.length !== givenBuf.length) return false;
  return timingSafeEqual(expectedBuf, givenBuf);
}

export type PaymentStatus = "succeeded" | "refunded" | "failed";

/// Maps the gateway's vocabulary onto ours.
///
/// Everything unrecognised becomes `failed`, deliberately. The alternative —
/// treating an unknown status as success, or leaving the payment pending —
/// either takes money for a booking that did not pay or leaves a customer
/// confirmed against a charge that never landed. Failing is recoverable: the
/// retry path exists, and G3 tests it.
export function mapGatewayStatus(status: string | undefined | null): PaymentStatus {
  switch (status) {
    case "captured":
      return "succeeded";
    case "refunded":
      return "refunded";
    default:
      return "failed";
  }
}

export interface QuoteLineItem {
  label?: string;
  amountMinorUnits?: number;
}

/// How much wallet credit this order consumed, as a negative number, or null
/// when it consumed none.
///
/// The signed quote is the only authority for this. A positive or zero
/// "Wallet credit" line is treated as no debit rather than as a credit: this
/// function can only ever take money out, and a bug or a tampered quote must
/// not be able to turn it into a way to put money in.
export function walletDebitMinorUnits(lineItems: QuoteLineItem[] | undefined | null): number | null {
  if (!lineItems) return null;
  const line = lineItems.find((item) => item.label === "Wallet credit");
  const amount = line?.amountMinorUnits;
  if (typeof amount !== "number" || !Number.isFinite(amount) || amount >= 0) return null;
  return amount;
}
