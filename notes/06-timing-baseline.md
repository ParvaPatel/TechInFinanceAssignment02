# Timing baseline: all four modules written

*Written 2026-11-09. Previous: [05-modules.md](05-modules.md). Code: tag `baseline` (commit `6468b97`).*

## Contents

1. [Summary](#1-summary)
2. [Method](#2-method)
3. [Results](#3-results)
4. [Finding: the runs are identical](#4-finding-the-runs-are-identical)
5. [The critical path](#5-the-critical-path)
6. [What it means for the fix](#6-what-it-means-for-the-fix)
7. [Noise floor from different seeds](#7-noise-floor-from-different-seeds)

---

## 1. Summary

| | Result |
|---|---|
| Whole design | **18.84 MHz** (53.08 ns), under 20 MHz as the assignment says |
| Slowest module | **pricing, 18.88 MHz** (52.97 ns), unchanged from the starter (we didn't touch it) |
| Next slowest | quote_manager 42.76, book 42.87, order_table 49.91 MHz |
| Our modules | book 42.87, market_data_parser 158.40, sequence_check 167.25, order_encoder 273.15 MHz: all above 30 |
| Run-to-run noise | **zero**: 30 runs of `make timing` gave identical numbers in every module |
| Critical path | inside pricing: from its input register to its output register (85 cells) |

---

## 2. Method

- **Code:** tag `baseline`.
- **Runs:** 30 runs of `make timing`, each after `rm -rf build/timing`. That deletion is needed: `make timing` reuses its results until an RTL file changes, so without it you'd get the same report 30 times. Each report is saved as `build/timing-runs/baseline-N.txt`.
- **Tools:** Yosys 0.70 + nextpnr-ecp5 0.11.1, LFE5U-85F speed grade 6, goal 100 MHz. That's the Makefile's flow, unchanged.

```sh
mkdir -p build/timing-runs
caffeinate -i sh -c 'for i in $(seq 1 30); do rm -rf build/timing; make timing > build/timing-runs/baseline-$i.txt 2>&1; echo "run $i done"; done'
```

---

## 3. Results

**The whole design** (identical in all 30 runs):

| | |
|---|---|
| Max clock frequency | 18.84 MHz |
| Min clock period | 53.08 ns: 20.95 ns logic + 32.13 ns routing |
| Critical path | from `pricing.in_item` to `quote_manager.ask_decision` (section 5) |
| LUTs | 19,151 of 83,640 (22%) |
| Flip-flops | 7,166 of 83,640 (8%) |
| Block RAMs | 28 of 208 (13%): the order table |
| Multipliers | 32 of 156 (20%): pricing 28 + quote manager 4 |

**Each module on its own** (min = median = max across 30 runs):

| Module | Max MHz | Min period | LUTs | Written by |
|---|---|---|---|---|
| market_data_parser | 158.40 | 6.31 ns | 798 | us |
| sequence_check | 167.25 | 5.98 ns | 167 | us |
| report_parser | 175.07 | 5.71 ns | 889 | given |
| merge | 208.12 | 4.80 ns | 1,771 | given |
| order_table | 49.91 | 20.04 ns | 1,672 | given |
| **book** | **42.87** | 23.33 ns | **12,330** | us (`apply_update`) |
| **pricing** | **18.88** | **52.97 ns** | 2,714 | given, **slowest** |
| quote_manager | 42.76 | 23.39 ns | 2,602 | given |
| order_encoder | 273.15 | 3.66 ns | 227 | us |
| register_bank | 207.94 | 4.81 ns | 230 | given |

**Compared with Phase 0 (the starter):**
- The modules we didn't touch give exactly the same numbers: pricing 18.88, quote_manager 42.76, order_table 49.91, and so on.
- The whole-design figure went from 62.97 MHz, which was meaningless with the four modules empty, to 18.84 MHz, which is real.
- Block RAMs went from 0 to 28: synthesis now keeps the order table, because its results can reach an output.

---

## 4. Finding: the runs are identical

All 30 runs gave the same figures, to 0.01 MHz, for the whole design and for every module.

**Why:** the Makefile doesn't pass `--seed` to nextpnr, so placement always starts from the same default seed. The same netlist with the same seed gives the same placement, and so the same timing.

**What "not perfectly deterministic" (assignment.pdf) must therefore mean:** variation that comes from **changing the design**. Any RTL edit gives a different netlist, which gives a different placement. So the whole-design figure can move a few percent even in parts you didn't touch. That's the noise a real improvement must be separated from, and repeating identical runs can't show it.

**Lesson, compared with Assignment 1:**
- In Assignment 1, repeating the same run *was* the way to see the noise: caches, the OS and power all varied.
- Here, the cycle count has no noise at all, and repeating the timing run gives no new information.
- The noise has to be made visible deliberately, with different placement seeds (section 7).

---

## 5. The critical path

From the whole design's log (`build/timing/market_maker/pnr.log`):
- **Source:** `dut.pricing.in_item_TRELLIS_FF_Q_14`: one of pricing's input registers.
- **Sink:** `dut.quote_manager.$45.ask_decision_TRELLIS_FF_Q_31`, at its `LSR` pin (the flip-flop's set/reset input).
- **85 cells** along the way: 0.52 ns clock-to-output at the start, 0.42 ns setup at the end, 53.08 ns in total.

**Reading it:** the end point is a **flip-flop** named after a quote manager signal. The most likely explanation is that it's **pricing's own output register for `ask_price`**:
- The quote manager uses pricing's `ask_price` directly as its ask request's price (`decision.request.price = {32'd0, desired_price}`, in `decide_side`).
- After synthesis flattens the design, the wire out of that register is named after this quote manager signal.
- The `LSR` pin fits too. `ask_price = can_quote ? … : '0` can be built as a register that is **reset to 0** when `can_quote` is false, so the path ends at the reset pin.

**Supporting this:** the period matches pricing on its own (53.08 vs 52.97 ns).

**What pricing does along that path, in one cycle and in order** ([rtl/pricing.sv](../rtl/pricing.sv)):

1. `spread = ask − bid` (32-bit subtract);
2. 16 comparisons to find the spread in ticks, S;
3. `S × bid size` (a multiply, on DSP blocks);
4. 15 × 37-bit comparisons of `k × (bid size + ask size)` against it;
5. pick the largest k that holds;
6. `k × 100`, then add to the bid price;
7. compare with the credit, and subtract or add the credit.

Each step waits for the one before. That's why the path is 85 cells long, and 60% of its time is routing between them.

---

## 6. What it means for the fix

- **Pricing is the only module under 30 MHz.** Every other one is at 42.76 MHz or above.
- So fixing pricing alone should lift the whole design to at most **about 42 MHz**, the next ceiling, set by the quote manager (42.76) and the book (42.87).
- The **30 MHz target** needs pricing's longest path cut from about 53 ns to under 33.3 ns.
- **The book is not a problem for timing, but it is big:** 12,330 LUTs, 64% of the design. That's the price of comparing all 16 levels at once, on both sides, with an adder per slot. It's affordable: 22% of the chip in total.

---

## 7. Noise floor from different seeds

**Result (later on 2026-11-09):** measured on the final fix rather than on the baseline. The fix landed close enough to 30 MHz to need it. Whole design, seeds 1–10: **31.63 / 32.44 / 34.64 MHz** (min / median / max), about 10% spread. Details in [notes/07](07-clock-fix.md), section 6.

**Originally deferred.** It wasn't needed while the expected effect (about double the clock speed) was far larger than the noise (a few percent, per assignment.pdf). It was to be run if either:

- the fix lands **close to 30 MHz**, where a few percent decides pass or fail; or
- two fixes or cut points come out **close to each other**, where we need the noise to tell them apart.

**How:** place and route the same netlist with different seeds, through nextpnr directly, with the Makefile's own options plus `--seed`. The Makefile is not changed.

```sh
mkdir -p build/seed-runs
caffeinate -i sh -c 'for d in market_maker pricing; do for s in 1 2 3 4 5 6 7 8 9 10; do echo "$d $s"; done; done | xargs -P 8 -n 2 sh -c '"'"'tools/oss-cad-suite/bin/nextpnr-ecp5 --85k --package CABGA381 --speed 6 --out-of-context --freq 100 --timing-allow-fail --seed $1 --json build/timing/$0/synthesized.json > build/seed-runs/$0-seed$1.log 2>&1; echo "$0 seed $1 done"'"'"''
```

**Interview answer, without it:** "`make timing` is deterministic on my machine: 30 runs, identical. The variation the assignment mentions comes from placement changing when the design changes, a few percent. My change roughly doubled the clock speed, far beyond that."
