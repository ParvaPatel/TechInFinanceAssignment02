# The four modules we wrote

*Started 2026-11-09. Previous: [02-build-setup.md](02-build-setup.md). Sections are added as each module is finished.*

## Contents

1. [Market data parser](#1-market-data-parser)
2. [Sequence check](#2-sequence-check)
3. [Order encoder](#3-order-encoder)
4. [Book](#4-book)
5. [The whole pipeline: results](#5-the-whole-pipeline-results)

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

---

## 2. Sequence check

**File:** [rtl/sequence_check.sv](../rtl/sequence_check.sv) · **Tests:** 0/8 → **8/8 pass**, with no Verilator warnings under `-Wall` (2026-11-09).

### What it does

The feed numbers its messages 1, 2, 3, …. This stage:
- spots a missed (or repeated) message;
- sets the sticky `sequence_gap` flag on that item and every item after it;
- wraps each event in a `pipeline_item_t` (`source = SOURCE_MARKET_DATA`).

It's registered (1 cycle), and can accept an event every cycle.

### The two registers it adds

| Register | Width | Reset value | Holds |
|---|---|---|---|
| `expected_sequence` | 64 bits (the sequence number is a u64) | 1, because the feed starts at 1 | The number the next message should carry |
| `gap_seen` | 1 bit | 0 | A gap has happened since reset: the sticky memory |

### The logic, every cycle

```
gap = gap_seen || (valid && sequence_number != expected_sequence)

if valid:  expected_sequence ← sequence_number + 1     (gap or not)
           gap_seen          ← gap
else:      both unchanged                              (idle cycles don't count)

output: valid = market_event_valid, item = {market data, the event, sequence_gap = gap}
```

**Worked example: a repeated message (1, 2, 2, 3):**

| Message | Expected | Not equal? | `gap_seen` before | Gap flag out | Expected after |
|---|---|---|---|---|---|
| 1 | 1 | no | 0 | 0 | 2 |
| 2 | 2 | no | 0 | 0 | 3 |
| 2 | 3 | **yes** | 0 | **1** | 3 |
| 3 | 3 | no | 1 | **1** (sticky) | 4 |

### Decision cards

**A separate `gap_seen` register instead of reusing the output's flag**
- *What:* a 1-bit register with its own reset, rather than reading `item.errors.sequence_gap` back as the memory.
- *Why:* the output item is a data register with **no reset**. After a reset it could hold anything, and the "restarts at one" test would fail. `gap_seen` is a control bit, so it's reset.
- *Trade-off:* one extra flip-flop. Negligible.

**The gap is sticky**
- *Why:* after a missed message the book is wrong for good. The missed message may have added or removed liquidity we'll never learn about. Nothing later can repair it, so every later item must carry the flag, and the quote manager halts.
- *Alternative:* flag only the message that reveals the gap. Rejected: the items after it are just as untrustworthy, and the halt must not depend on catching one particular item.

**Expected becomes the message's number + 1, even after a gap**
- *What:* follow the feed from where it is now (design.pdf 2.2: "Either way…").
- *Why:* it keeps the counter meaning "the next message the feed should send". With a sticky flag it changes no flag value. It matters only for how the stage would behave if the flag weren't sticky.

**A repeated number counts as a gap**
- *Why:* it's simply "number ≠ expected". A repeat means the feed or network misbehaved, so the stream can no longer be trusted (the file's own comment: "missed (or arrived twice)").

**Idle cycles change nothing**
- *What:* both registers update only when `market_event_valid` is high.
- *Why:* the test leaves sequence 999 on the bus during idle cycles. Without the valid check, that junk would look like a gap.

**`logic gap;` inside `always_comb`**
- *What:* a temporary name for a value computed and used in the same cycle. It's not a register, so no flip-flop is created.
- *Why:* the same value is used twice, for the output flag and for `gap_seen_next`. Naming it avoids writing the expression twice.

**Speed:** a 64-bit comparison and a 64-bit +1, done side by side on fast carry chains. This module should be among the fastest.

### Likely questions

1. Why does the expected number start at 1? *(The feed numbers from 1; set by reset.)*
2. Message 5 arrives when 4 was expected. What's flagged, and what's expected next? *(5 is flagged; 6 is expected.)*
3. Why keep a separate `gap_seen` register? *(The output register isn't reset.)*
4. Why does a gap halt everything, and why permanently?
5. What would go wrong if the registers updated on idle cycles too?
6. Where does the halt actually happen, and why not here? *(In the quote manager: only it knows our orders' tokens; one place decides; the flag stays on the exact message.)*

---

## 3. Order encoder

**File:** [rtl/order_encoder.sv](../rtl/order_encoder.sv) · **Tests:** 0/5 → **5/5 pass**, with no Verilator warnings under `-Wall` (2026-11-09).

### What it does

The parser in reverse. It takes one `order_request_t` from the quote manager and produces one whole order message on a 512-bit bus, registered (1 cycle later). Each field is written at its fixed byte offset, and every other byte is 0. The tests compare **all 64 bytes** against the simulator's own C++ encoding of the same order.

### The layouts it writes

| Message | Byte 0 | Fields | From |
|---|---|---|---|
| EnterOrder (25 bytes) | `'O'` | token @1 (8), side @9 (1), shares @10 (4), instrument @14 (2), price @16 (8), time in force @24 (1) | side: `is_buy ? 'B' : 'S'`; instrument = 1 and time in force = `'D'` are constants |
| ReplaceOrder (29 bytes) | `'U'` | existing token @1 (8), replacement token @9 (8), shares @17 (4), price @21 (8) | byte 1 ← `existing_token`; byte 9 ← `token` |
| CancelOrder (13 bytes) | `'X'` | token @1 (8), shares remaining @9 (4) | shares = 0 cancels the whole order |

Writing a field is the mirror of reading one: `order_data_next[8*o +: 8*n] = value`.

### Decision cards

**Zero the whole message first, then write one kind's fields**
- *What:* `order_data_next = '0` before the `case`.
- *Why:* bytes past the end of the message must be 0 (the receiving C++ reads the length from the type byte, and the test checks all 64 bytes). Every bit is also assigned on every path, so no latch.

**The request's `token` is the *replacement* in a ReplaceOrder**
- *What:* byte 1 gets `existing_token`, byte 9 gets `token`.
- *Why:* the wire format puts the order being replaced first. The request reuses one `token` field for "the order this message is about", which for a replace is the new one.
- *Trap:* swapping the two would replace the wrong order. The test's two tokens differ in every byte, so a swap fails immediately.

**Constants where the request has no field**
- *What:* the type byte, instrument (1) and time in force (`'D'`) come from `messages_pkg.sv`.
- *Why:* there's only one instrument (`sim::kInstrument`), and our quotes always rest on the book, so they are always Day orders, never IOC.

**Unknown kind gives no message**
- *What:* valid starts from `request_valid`; `default:` clears it.
- *Why:* the 2-bit `kind` field can hold 3, which has no meaning. Sending garbage to an exchange is worse than sending nothing. `Fpga::Unload` would also throw on an unknown type byte ([app/fpga.cpp:46-47](../app/fpga.cpp#L46-L47)).

**Speed:** each output byte is chosen from at most three inputs, which is the only logic. This should be one of the fastest modules.

### Likely questions

1. What's at byte 9 of a ReplaceOrder, and why not the existing token?
2. Which fields don't come from the request? Why?
3. What does a cancel with shares = 0 mean, and why does halting use it? *(Reduce the order to 0 shares, i.e. cancel it entirely. The quote manager's cancel-all builds exactly this.)*
4. Why must the bytes after the message be zero?
5. What happens if the quote manager sends kind = 3?

---

## 4. Book

**File:** [rtl/book.sv](../rtl/book.sv), function `apply_update` (the rest of the module was given) · **Tests:** 4/15 → **15/15 pass**, with no Verilator warnings under `-Wall` (2026-11-09). The 4 that passed before did so trivially: an empty book that never changes is enough for them.

### What was given, what we wrote

| Part | Status |
|---|---|
| The registers (`bids`, `asks`, sticky `overflow_seen`, second-cycle state) | Given |
| Update 0 in the item's first cycle, update 1 in its second | Given |
| Choosing the bid or ask side; output top of book, `book_overflow`, `book_invalid` | Given |
| **`apply_update(levels, update)`**: one level update applied to one side | **Ours** |

### How a side is stored

16 slots of `{valid, price, size}`, **best first** (bids highest first, asks lowest first). Valid levels are packed at the top, empty slots at the bottom. The top of book is slot 0, which is wires straight to the output, so reading it is free.

### The cases

| Update | Case | Result | Overflow? |
|---|---|---|---|
| Price exists, add | Size change | That slot's size + shares | no |
| Price exists, remove less than its size | Size change | That slot's size − shares | no |
| Price exists, remove ≥ its size | Delete | Every worse slot moves up one; the last becomes empty | no |
| New price, add | Insert | New level at its sorted place; every worse slot moves down one | **yes, if slot 15 was valid**: the worst falls off, or a worse-than-all price can't be stored |
| New price, remove | Untracked level | Nothing changes | **yes**: can only happen after an earlier overflow |
| `valid` = 0 | No update | Nothing changes | no |

### How the code works: all 16 slots at once

**1. Masks:** one bit per slot, all computed in parallel.

| Mask | Bit i is 1 when |
|---|---|
| `is_better` | slot i is valid and better than the update's price |
| `is_match` | slot i is valid and at exactly the update's price |
| `is_emptied` | slot i matches, and the update removes ≥ its size |
| `is_new` | slot i isn't better, but the slot above it is (or it's slot 0) |

Because the list is sorted, `is_better` is always a run of 1s followed by 0s. That makes `is_new` one line: `~is_better & {is_better[LEVELS-2:0], 1'b1}`.

```
insert 100.01 into bids [100.02, 100.00, 99.98, empty …]

is_better                     1 0 0 0 …
shifted down, top filled      1 1 0 0 …
AND NOT is_better        →    0 1 0 0 …   → the new level goes in slot 1
```

**2. Neighbours:** `moved_up` and `moved_down` are the whole side shifted by one level's width. So `moved_up[i]` is slot i + 1 and `moved_down[i]` is slot i − 1, with an empty level shifted in at the end.

**3. One branch per case.** Each slot picks its new value from itself, a neighbour, or the new level:

| Branch | Slots with `is_better` | `is_new` slot | Other slots |
|---|---|---|---|
| Size change | unchanged | — | matching slot: size ± shares |
| Delete | unchanged | — | `moved_up` |
| Insert | unchanged | new level | `moved_down` |

### Decision cards

**All 16 slots in parallel, not a find-then-shift loop**
- *What:* every slot compares itself with the update at the same time. Each new value is chosen from a couple of mask bits and the neighbours.
- *Why:* a loop is a **chain**. Each step waits for the one before, so the path from register to register grows with the number of levels, and the clock must slow down. In parallel, the longest path is one 32-bit comparison, a 16-bit OR, and a small choice per slot, whatever the number of levels.
- *Trade-off:* area. 16 comparators and 16 adders instead of 1 each. The FPGA has plenty of LUTs; time per cycle is the scarce resource.
- *Evidence:* to measure in Phase 4 (book fmax), and optionally in Phase 5b (a loop version on an experiment branch).

**Each slot has its own adder for size changes**
- *What:* `levels[i].size ± update.shares` for each slot; only the matching slot uses its result.
- *Why:* a single shared adder would first need a 16-way choice ("which slot matched?"), then the add, then a write back. That's a longer path. 16 small adders side by side keep the path short.
- *Trade-off:* about 16 × 32-bit adders' worth of LUTs.

**Neighbours as shifted copies, not `levels[i+1]`**
- *Why:* for slot 15, `levels[i+1]` would point at slot 16, which doesn't exist. Even in a branch that never runs, Verilator's strict mode may flag the out-of-range index. A shift fills in an empty level at the end automatically. It's the same hardware: wires, no logic.

**16 levels, and halt on overflow instead of refilling**
- *Why 16:* every level adds a comparator, an adder and a choice to every update, and about 65 flip-flops. More levels means more area and a longer OR across the matches, so a slower clock. 16 is enough to follow the top of a normal book.
- *Why halt:* once a level has been dropped, the book can't be trusted. When the better levels empty, the dropped level should become visible, and the book doesn't know it. So `book_overflow` is sticky and the quote manager halts.
- *Alternative:* back the 16 registers with a full-depth store, and refill from it (the module's own comment: "Real systems back a cache like this with a full-depth store"). Rejected here as out of scope: it needs a second structure and a refill path.
- *Note:* inserting a **better** price into a full side also overflows. The worst level is pushed out, and later it might need to come back.

**One update per cycle, so a replace takes two cycles**
- *Why:* applying two updates in one cycle would chain a second compare-and-shift after the first, making the path roughly twice as long. Taking 2 cycles per item keeps one compare-and-shift per cycle.
- *Cost:* the pipeline accepts one item every **2** cycles (II = 2), which the merge enforces. Throughput, not latency, is what's given up.
- *Evidence:* the design doc says "several times larger and slower". Measuring it is optional experiment 5b.

**Removing ≥ the level's size deletes it**
- *Why:* "≥" rather than "=" means a level never wraps around to a huge size by subtracting too much. The order table already caps what it removes at an order's remaining shares, so in practice it's "=".

**`book_invalid` is per item, `book_overflow` is sticky**
- *Why:* an empty side or a crossed book is a real market state that the next message can fix, so we just skip quoting for that item. A dropped level can never be recovered, so it's for good.

### Compared with the C++ book (Assignment 1), for write-up question 2

| | C++ (`app/market_data/book.cpp`, Assignment 1) | FPGA (`book.sv` + `order_table.sv`) |
|---|---|---|
| Depth | Every price: one ladder slot per tick, up to $2,000 | Best 16 levels per side |
| Finding a level | Index the ladder by price ÷ tick: one memory access | Compare against all 16 at once |
| New best after the top empties | Scan the ladder from the old best until a non-empty tick: a loop of varying length | Everything moves up one slot, in the same cycle: fixed time |
| Order lookup by ref | A flat array of 2²⁰ entries, ref = index, no collisions | 4,096-entry block RAM, direct-mapped by ref mod 4,096, with tags; a collision halts |
| When it runs out | Throws if a price or ref is out of range | Sticky overflow / unknown order, and halt |
| Time per update | Varies (cache misses, the scan) | Always 1 cycle per update, 2 per item |
| Strength it plays to | Big, cheap memory; flexible loops and branches | Parallel comparison; fixed, predictable timing; registers next to the logic |

### Likely questions

1. Walk me through inserting a new best bid into a full side.
2. Why compare against all 16 levels at once? What would a loop cost?
3. Why only 16 levels? What happens on a 17th, and why not refill?
4. Why does a replace take two cycles, and what does that cost the pipeline?
5. What's `is_better`, and why is it always 1s then 0s?
6. Removing shares at a price that isn't in the book: when could that happen?
7. How does your book differ from your Assignment 1 C++ book, and why is each right for its platform?

---

## 5. The whole pipeline: results

**2026-11-09, after all four modules (the commit that will be tagged `baseline`):**

| Check | Phase 0 (starter) | Now |
|---|---|---|
| `make test-holes` | 4/33 (all trivial) | **33/33** |
| `make verify` | 0/10 | **10/10**: every order identical to the expected files |
| `build/market_maker sim/fixtures/basic.scn` | 0 orders | **14 orders**, 2,989 cycles simulated |

**Latency on `basic`** (printed by `build/market_maker`, in clock cycles): **min 8, median 9, p99 10, max 10.**

| Number | Order | Why |
|---|---|---|
| 8 | First order caused by an execution report | Reports skip the sequence check: 9 register stages |
| 9 | First order caused by market data | 10 register stages; `Fpga` counts the input's cycle as cycle 0 |
| 10 | The second order of a pair (usually the ask) | The encoder takes one request per cycle |

This matches the design doc's 9 and 8, and the stage count in [notes/01](01-project-overview.md). The cycle-by-cycle waveform view is Phase 3.
