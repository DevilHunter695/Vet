// Supabase Edge Function: POST /v1/quotes (plan Appendix A + §6.2).
//
// Pricing is server-computed and signed here — the client sends only its
// cart_id; every rupee in the response is derived from Postgres rows the
// client cannot write. An order (a later migration) must reference a valid,
// unexpired, correctly-signed quote_id, so client-side price tampering is
// structurally impossible rather than merely discouraged.
//
// The formula mirrors VetCircuit/Domain/UseCases/PricingEngine.swift
// (Appendix C) — kept in sync by hand today; if the two drift, treat it as
// a bug per the plan's closing rule ("when a section here and the code
// disagree, one of them is a bug").

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { createHmac } from "node:crypto";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const quoteSigningSecret = Deno.env.get("QUOTE_SIGNING_SECRET")!;

const supabase = createClient(supabaseUrl, serviceRoleKey);
const QUOTE_TTL_SECONDS = 10 * 60;
const GST_RATE = 0.18;

interface LineItem {
  label: string;
  amountMinorUnits: number;
}

function computeLineItemsForItem(variant: any, addons: any[], additionalPetCount: number, travelFeeMinorUnits: number): LineItem[] {
  const lineItems: LineItem[] = [];
  lineItems.push({ label: variant.name, amountMinorUnits: variant.price_minor_units });

  const multiPet = additionalPetCount * variant.additional_pet_price_minor_units;
  if (multiPet > 0) lineItems.push({ label: `Additional pet(s) ×${additionalPetCount}`, amountMinorUnits: multiPet });

  for (const addon of addons) lineItems.push({ label: addon.name, amountMinorUnits: addon.price_minor_units });

  if (travelFeeMinorUnits > 0) lineItems.push({ label: "Travel fee", amountMinorUnits: travelFeeMinorUnits });

  return lineItems;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response(JSON.stringify({ code: "UNAUTHENTICATED", message: "Sign in required." }), { status: 401 });

  const { cart_id, use_wallet_balance } = await req.json();
  if (!cart_id) return new Response(JSON.stringify({ code: "VALIDATION", message: "cart_id is required." }), { status: 400 });

  const { data: cart, error: cartError } = await supabase.from("carts").select("*").eq("id", cart_id).single();
  if (cartError || !cart) return new Response(JSON.stringify({ code: "NOT_FOUND", message: "Cart not found." }), { status: 404 });

  const { data: items } = await supabase.from("cart_items").select("*").eq("cart_id", cart_id);
  if (!items || items.length === 0) {
    return new Response(JSON.stringify({ code: "VALIDATION", message: "Cart is empty." }), { status: 400 });
  }

  let lineItems: LineItem[] = [];
  let total = 0;
  const travelFeeMinorUnits = cart.circuit_id ? 0 : 4500; // 0 if slot is on an existing circuit run (density dividend)

  for (const item of items) {
    const { data: variant } = await supabase.from("service_variants").select("*").eq("id", item.variant_id).single();
    if (!variant) return new Response(JSON.stringify({ code: "NOT_FOUND", message: "Service variant not found." }), { status: 404 });
    const { data: addons } = await supabase.from("addons").select("*").in("id", item.addon_ids ?? []);
    const additionalPetCount = Math.max(0, (item.pet_ids?.length ?? 1) - 1);

    const itemLines = computeLineItemsForItem(variant, addons ?? [], additionalPetCount, travelFeeMinorUnits);
    lineItems = lineItems.concat(itemLines);
    total += itemLines.reduce((sum, li) => sum + li.amountMinorUnits, 0);
  }

  // E4/N2: coupon discount, validated (never trusted from the client) via
  // validate_coupon() against this cart's real pre-discount subtotal —
  // capped at that subtotal, same rule PricingEngine.swift enforces.
  let discount = 0;
  if (cart.coupon_code) {
    const { data: coupons } = await supabase.rpc("validate_coupon", {
      p_code: cart.coupon_code,
      p_user_id: cart.user_id,
      p_cart_total: total,
    });
    const coupon = coupons?.[0];
    if (coupon) {
      const raw = coupon.discount_type === "percentage_off"
        ? Math.floor((total * coupon.discount_value) / 100)
        : coupon.discount_value;
      discount = Math.min(raw, total, coupon.max_discount_minor_units ?? raw);
      if (discount > 0) lineItems.push({ label: "Discount", amountMinorUnits: -discount });
    }
  }
  const taxable = Math.max(0, total - discount);

  const gst = Math.round(taxable * GST_RATE);
  if (gst > 0) lineItems.push({ label: `GST (${Math.round(GST_RATE * 100)}%)`, amountMinorUnits: gst });
  total = taxable + gst;

  // G6: wallet credit applied last, after tax, capped at what's owed — the
  // real balance is looked up server-side, never trusted from the client.
  if (use_wallet_balance && cart.user_id) {
    const { data: ledger } = await supabase.from("wallet_ledger").select("amount_minor_units").eq("user_id", cart.user_id);
    const balance = (ledger ?? []).reduce((sum: number, row: any) => sum + row.amount_minor_units, 0);
    const walletApplied = Math.min(Math.max(0, balance), total);
    if (walletApplied > 0) {
      lineItems.push({ label: "Wallet credit", amountMinorUnits: -walletApplied });
      total -= walletApplied;
    }
  }

  const expiresAt = new Date(Date.now() + QUOTE_TTL_SECONDS * 1000).toISOString();
  const payload = JSON.stringify({ cart_id, total, expiresAt });
  const signature = createHmac("sha256", quoteSigningSecret).update(payload).digest("hex");

  const { data: quote, error: insertError } = await supabase
    .from("quotes")
    .insert({
      cart_id,
      breakdown: { lineItems, totalMinorUnits: total },
      total_minor_units: total,
      signature,
      expires_at: expiresAt,
    })
    .select()
    .single();

  if (insertError || !quote) {
    return new Response(JSON.stringify({ code: "UNKNOWN", message: "Could not create quote." }), { status: 500 });
  }

  return new Response(JSON.stringify(quote), { status: 200, headers: { "Content-Type": "application/json" } });
});
