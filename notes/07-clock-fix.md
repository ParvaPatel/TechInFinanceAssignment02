# The clock fix: pricing split into two pipeline stages

*Written 2026-11-09. Previous: [06-timing-baseline.md](06-timing-baseline.md). Code: branch `fix-pricing-pipeline`, merged into `main`.*

## Contents

1. [Summary](#1-summary)
2. [Where pricing's time went](#2-where-pricings-time-went)
3. [Cut 1: after the multiply (26.56 MHz)](#3-cut-1-after-the-multiply-2656-mhz)
4. [Cut 2: the 15 multiples moved into stage 1 (33.46 MHz)](#4-cut-2-the-15-multiples-moved-into-stage-1-3346-mhz)
5. [Correctness](#5-correctness)
6. [Placement noise: 10 seeds](#6-placement-noise-10-seeds)
7. [Decision cards](#7-decision-cards)
8. [Likely questions](#8-likely-questions)

---

## 1. Summary

| | Baseline | Cut 1 | **Cut 2 (final)** |
|---|---|---|---|
| Whole design, `make timing` | 18.84 MHz (53.08 ns) | 26.56 MHz (37.65 ns) | **33.46 MHz (29.89 ns)** |
| Whole design, 10 seeds | — | — | **31.63 / 32.44 / 34.64 MHz** (min / median / max) |
| pricing on its own | 18.88 MHz | 26.89 MHz | 30.90 MHz |
| Slowest module | pricing | pricing | pricing |
| `make verify` | 10/10 | 10/10 | **10/10** |
| Latency on `basic` (cycles) | 8 / 9 / 10 | 9 / 10 / 11 | **9 / 10 / 11** |
| Latency, market data → first order (calculated) | 9 × 53.08 ≈ **478 ns** | 10 × 37.65 ≈ 377 ns | 10 × 29.89 ≈ **299 ns** |
| LUTs / flip-flops (whole design) | 19,151 / 7,166 | 19,340 / 7,443 | 19,084 / 7,840 |

`make timing` was run 30 times on the baseline and 5 times on each cut, each time after `rm -rf build/timing`. Every run of the same code gave identical numbers.

**In one sentence:** a register in the middle of pricing splits its 53 ns chain of arithmetic into two halves of about 25–30 ns each. The clock can then tick almost twice as fast, at the cost of one extra cycle of latency, and the order still comes out about 37% sooner in time.

---

## 2. Where pricing's time went

From nextpnr's critical-path report for pricing on its own (`build/timing/pricing/pnr.log`, baseline). Each hop is labelled with the source line it comes from:

| Step | Code (baseline `pricing.sv`) | Path reaches it at | Time |
|---|---|---|---|
| 1. spread = ask − bid | line 65 | 0.5 ns | ~4.3 ns |
| 2. spread in ticks S: 16 compares, keep the last that holds | lines 70–72 | 4.79 ns | **~15.7 ns** |
| 3. S × bid size (multiplier blocks) | line 73 | 20.46 ns | ~5.1 ns |
| 4. 15 compares of k × total ≤ S × bid; keep the largest k | lines 79–84 | 25.58 ns | **~17.7 ns** |
| 5. tick below = bid + k × 100; credit; output | lines 86–98 | 43.29 ns | ~9.7 ns |
| | | | **52.97 ns** |

**Steps 2 and 4 take two-thirds of the time.** Each is "compare, then keep the last true one", written as a `for` loop that overwrites a variable. In hardware that becomes a **chain of 15–16 choices**, each waiting for the one before. The multiply itself is cheap, because it runs on dedicated multiplier blocks.

---

## 3. Cut 1: after the multiply (26.56 MHz)

**The plan:** stage 1 = steps 1–3 (25.6 ns); stage 2 = steps 4–5 (27.4 ns); about 35 MHz expected.

**What we stored in the middle register:** `spread`, `spread_ticks`, `total_size`, `weighted` (= S × bid size), the bid price, and the item's `source`, `report_event` and `errors`. Only the fields stage 2 actually reads, because Verilator's strict mode fails the build on stored bits that are never read.

**Result:** 26.56 MHz for the whole design, 26.89 for pricing. Better, but under 30, and well short of the estimate.

**Why it fell short:**
- The new critical path started at the **`stage_total_size`** register, and spent ~26 ns before reaching the tick calculation.
- Step 4 needs the 15 multiples `1 × total_size … 15 × total_size`. They depend only on the total size, which is known in the first few nanoseconds.
- **In the original design they were computed in parallel with steps 1–3, off the critical path**, so the path report never showed them.
- The cut put `total_size` behind the register. So the 15 multiplications now *started* at the beginning of stage 2, **in series** before the compares: about +9 ns on stage 2.

**Lesson:** a critical-path report only shows the work **on** that path. Work running in parallel *off* the path can land *on* it once a register moves. Plan a cut from the whole dependency picture, not just the slowest path.

---

## 4. Cut 2: the 15 multiples moved into stage 1 (33.46 MHz)

**The change:** compute `j × total_size` for j = 1–15 in **stage 1**, and store all 15 in the middle register (`stage_multiples[1..15]`, 15 × 37 bits) instead of `total_size`. Stage 2 then starts directly at the compares.

```
stage 1:  spread ──► S ──► S × bid size ─────────┐
          bid + ask sizes ──► 15 multiples ──────┤   (side by side)
═════════════════════ middle register ═══════════╪═══════════════════
stage 2:  15 compares ──► keep largest k ──► tick below ──► credit ──► output
```

**Result:** 33.46 MHz for the whole design (29.89 ns: 10.65 logic + 19.24 routing), 30.90 MHz for pricing alone. The whole design's critical path now runs from `pricing.stage_weighted` through stage 2. So stage 2 is still the limit, and pricing is still the slowest module.

**Cost:** +397 flip-flops over cut 1 (7,443 → 7,840), and slightly fewer LUTs. Flip-flops are 9% used.

---

## 5. Correctness

- `make verify`: **10/10** after each cut. Every order is identical to the expected files.
- `make test-holes`: 33/33 (pricing has no unit test; this confirms nothing else moved).
- Latency on `basic`: **min 9, median 10, max 11**, exactly +1 on every order.

**Why it can't change an order:**
1. **The arithmetic is unchanged, line for line.** Stage 2 reads `stage_*` registers where it used to read the same values directly, and `stage_multiples[j]` holds exactly the old `37'(j) * {4'd0, total_size}`.
2. **Pricing keeps nothing between items**, and items arrive at least 2 cycles apart (the merge's limit), so the middle register is always free when a new item arrives.
3. **The extra cycle doesn't move simulated time:** each message runs to completion while simulated time stands still ([notes/01](01-project-overview.md), section 1).
4. **`credit`** is read in stage 2, where it's used. It changes only on a CPU register write, which happens only while the pipeline is idle.

---

## 6. Placement noise: 10 seeds

`make timing` is deterministic: no `--seed`, so every run gives the same placement. To see the variation, the final netlists were placed and routed with seeds 1–10, using the Makefile's own nextpnr options plus `--seed`. The command is in [notes/06](06-timing-baseline.md), section 7.

| Cut 2, seeds 1–10 | Min | Median | Max | Spread |
|---|---|---|---|---|
| **Whole design** | **31.63** | **32.44** | 34.64 MHz | 9.5% |
| pricing on its own | 30.15 | 31.26 | 35.04 MHz | 16% |

**What it shows:**
- **Every placement of the whole design is above 30 MHz.** Even the worst (31.63) is +68% over the baseline. Noise of about 10% can't explain a change that big.
- `make timing`'s 33.46 MHz is a better-than-median placement. **Quote both:** "33.46 MHz from `make timing`; 31.6–34.6 MHz, median 32.4, across 10 seeds."
- **Placement noise is about 10% for the whole design, 16% for pricing alone**, larger than the assignment's "a few percent". The same logic also came out 8% apart in two different `make timing` contexts: 30.90 MHz alone vs 33.46 MHz in the whole design.
- **The margin is thin for pricing alone** (min 30.15). But the whole design is what runs on the chip.

The baseline wasn't seed-swept. Its netlist was replaced before the seed runs, and with an effect this large compared with the noise, it isn't needed.

---

## 7. Decision cards

**Pipelining: a register in the middle of pricing**
- *What:* split pricing into two stages, with a register between them. Pricing now takes 2 cycles.
- *Why:* the clock period must be longer than the slowest register-to-register path. Pricing's path was 53 ns, all in one cycle. Cutting it in two gives two paths of about 25–30 ns, so the clock can nearly double.
- *Cost:* latency +1 cycle (9 → 10). But each cycle is now much shorter, so the order is out sooner: about **299 ns vs 478 ns** (calculated).
- *Why it's safe:* pricing keeps nothing between items, and items arrive at least 2 cycles apart. So throughput (II = 2) is unchanged, and no item can overwrite another.

**Why pricing, and only pricing**
- *Why:* it was the only module under 30 MHz (18.88). Every other was at 42.76 MHz or above. Since every register shares one clock, no change elsewhere could raise the design above pricing's speed.
- *Ceiling:* after pricing, the next limit is about 42 MHz (quote_manager 42.76, book 42.87).

**Why this cut point**
- *What:* after the multiply, plus the 15 multiples moved before the register.
- *Why:* that splits the measured 53 ns closest to halfway (25.6 ns before, about 27–30 ns after), and everything stage 2 needs is ready by then.
- *Evidence:* cut 1 vs cut 2, measured. Cut 1 left work in stage 2 that the critical-path report had hidden (section 3).

**Alternatives considered**

| Alternative | Why not (for now) |
|---|---|
| A divider for the microprice | Far larger and slower: the reason pricing avoids division in the first place |
| Restructure without adding a cycle (e.g. replace the "keep last true" chains) | Possible: steps 2 and 4 are chains of 15–16 choices. But the compare results are always 1s then 0s, so the boundary can be found in one step, the same mask trick as the book's `is_new`. More code to change and to verify; kept as optional experiment 5b |
| A third stage | Not needed: two stages already exceed 30 MHz for every seed. It would add another cycle |
| Telling the tools pricing may take 2 cycles (a "multicycle path"), since items come only every 2 cycles anyway | The Makefile's flow has no such constraints, so `make timing` would still count it as one cycle. It also relies on a timing promise rather than a register, which is fragile if the merge's rate ever changed |

---

## 8. Likely questions

1. Why was the design under 20 MHz? How did you find out which module was responsible? *(The `make timing` per-module report; pricing 18.88, everything else ≥ 42.76.)*
2. What exactly did you change, and why does it raise the clock? *(The period must cover the slowest path; a register cuts it in two.)*
3. Why does the extra cycle not change any order? *(Same arithmetic; no state between items; items ≥ 2 cycles apart; simulated time frozen. `make verify` 10/10.)*
4. Isn't the latency worse now? *(10 vs 9 cycles, but about 299 vs 478 ns.)*
5. Your first cut reached only 26.56 MHz. Why? *(Hidden parallel work, section 3.)*
6. How do you know 33.46 MHz isn't luck? *(10 seeds: 31.6–34.6, all above 30; baseline 18.84.)*
7. What limits the clock now, and what would you do next? *(Still pricing's stage 2, the "keep largest k" chain; the mask trick, or a third stage. After pricing, about 42 MHz: quote_manager and book.)*
8. Why not just use a divider, or tell the tools it's a two-cycle path?
