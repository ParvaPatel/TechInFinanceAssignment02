# The four modules we wrote

*Started 2026-11-09. Previous: [02-build-setup.md](02-build-setup.md). Sections are added as each module is finished.*

## Contents

1. [Market data parser](#1-market-data-parser)
2. Sequence check (to do)
3. Order encoder (to do)
4. Book (to do)

How each module was written: the spec and tests were explained first, the logic predicted, then the code was pasted in by hand and the unit tests run.

---

## 1. Market data parser

**File:** [rtl/market_data_parser.sv](../rtl/market_data_parser.sv) · **Tests:** 0/5 → **5/5 pass**, with no Verilator warnings under `-Wall` (2026-11-09).

### What it does

One whole market data message arrives in one cycle, on a 512-bit bus. Byte 0 is in bits 0–7, and bytes past the end of the message are zero. The parser turns the message into a `market_data_event_t`, registered, so the event comes out exactly 1 cycle later.

### The byte layout it decodes

A field *n* bytes long at byte offset *o* is `in_data[8*o +: 8*n]`: start at bit 8 × *o* and take 8 × *n* bits.

| Type | Byte 0 | Fields read |
|---|---|---|
| AddOrder | `'A'` | sequence @3 (8 bytes), ref @19 (8), side @27 (1), shares @28 (4), price @32 (8) |
| OrderExecuted | `'E'` | sequence @3, ref @19, executed shares @27 (4) |
| OrderCancel | `'X'` | sequence @3, ref @19, canceled shares @27 (4) |
| OrderDelete | `'D'` | sequence @3, ref @19 |
| OrderReplace | `'U'` | sequence @3, original ref @19, new ref @27 (8), shares @35 (4), price @39 (8) |

Not decoded, because nothing downstream uses them: the instrument (@1), the timestamp (@11), and the match number of an OrderExecuted (@31).

### How the code works

1. **Defaults first:** valid = `in_valid`, and every field = 0.
2. **Same for every type:** the sequence number (@3) and order ref (@19) are filled in before looking at the type.
3. **`case` on byte 0:** each known type sets its `kind` and its own fields.
4. **`default:`** (unknown type) sets valid back to 0.
5. **`always_ff`** registers the result. Only the valid bit is reset.

**Example slice.** An AddOrder's price is bytes 32–39, so `in_data[8*32 +: 64]` covers bits 256–319. Writing `[319:256]` by hand risks an off-by-one; `+:` doesn't.

### Decision cards

**Decode the whole message in one cycle**
- *What:* all fields are picked out in parallel, in the same cycle.
- *Why:* the whole message is already present on the 512-bit bus, and every field is at a fixed offset. A field slice is just wires: no logic and no delay. The only real logic is an 8-bit comparison per type, plus a 5-way choice for each field.
- *Alternative:* read byte by byte, like a CPU loop or a network stream. Rejected: it would take many cycles for no benefit, since the bytes are already all there.
- *Trade-off:* a 512-bit-wide input is a lot of wires. On a real board, a 64-bit network link delivers 8 bytes per cycle, and something must first gather the message (design.pdf, 2.4).

**Fields a type doesn't carry are zero**
- *What:* `market_event_next = '0` first, then each type fills only its own fields.
- *Why:*
  - The output doesn't depend on leftover bytes. The unit test fills the timestamp and match number with all-ones to prove they don't leak into the event.
  - Every bit is assigned on every path, so no latch is created.
- *Example:* a Replace has no side byte, so `is_buy` stays 0. The order table takes the side from the original order instead.

**Valid = `in_valid` AND a known type**
- *What:* start from `in_valid`; the `default:` branch clears it.
- *Why:* "no message" and "unknown type" both give no event, with a single rule. The type check needs only an 8-bit comparison per type, done in parallel with the field slicing.

**Reset only the valid bit, not the 292 bits of event data**
- *Why:* the data is ignored whenever valid is low, so its value after reset doesn't matter. Leaving reset off saves logic and routing: the reset signal would otherwise have to reach 292 more flip-flops. Every module here follows this rule (control bits are reset, data is not).

**Offsets written as numbers, not named constants**
- *What:* `in_data[8*32 +: 64]` with a comment naming the field, instead of constants in `messages_pkg.sv`.
- *Why:* keeps every change inside the module we were asked to complete. `messages_pkg.sv` stays untouched.
- *Alternative:* `MARKET_DATA_*_OFFSET` constants next to the existing `REPORT_*_OFFSET` ones (the starter's TODO pointed there). Equally correct. Rejected to avoid changing a shared file.
- *Trade-off:* a bare `32` means nothing without its comment, so each slice has one.

### Likely questions

1. Why is this module fast? *(Slices are wires; only small comparisons and choices.)*
2. What happens on a message type the parser doesn't know? *(No event: valid stays low.)*
3. Why doesn't a Replace carry a side? Where does it come from? *(From the original order's entry in the order table.)*
4. Why is the event data not reset?
5. Byte 32, 8 bytes: which bits? *(256–319.)*
