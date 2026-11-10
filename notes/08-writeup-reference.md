# Write-up: reference text

*Written 2026-11-09. Previous: [07-clock-fix.md](07-clock-fix.md).*

This is **reference material** for writing your own answers, the same approach as Assignment 1's `notes/10`. Every number links to where it was measured or read.

## Contents

1. [Facts sheet](#1-facts-sheet)
2. [One-page version (about 560 words)](#2-one-page-version-about-560-words)
3. [Optional additions for the remaining space](#3-optional-additions-for-the-remaining-space)
4. [Long version](#4-long-version)
5. [AI-use statement: the facts to include](#5-ai-use-statement-the-facts-to-include)
6. [Checklist before submitting](#6-checklist-before-submitting)

---

## 1. Facts sheet

### Q1: the clock-speed change

| Fact | Value | Source |
|---|---|---|
| Whole design, before | 18.84 MHz (53.08 ns), identical over 30 runs | [06](06-timing-baseline.md) §3 |
| pricing alone, before | 18.88 MHz (52.97 ns), the only module under 30 MHz | [06](06-timing-baseline.md) §3 |
| Next slowest modules | quote_manager 42.76, book 42.87, order_table 49.91 MHz | [06](06-timing-baseline.md) §3 |
| Where pricing's 53 ns went | spread 4.3 · spread in ticks 15.7 · multiply 5.1 · find k 17.7 · ticks and credit 9.7 ns | [07](07-clock-fix.md) §2 |
| Cut 1 (after the multiply) | 26.56 MHz: the 15 multiples k × total size moved onto stage 2's path | [07](07-clock-fix.md) §3 |
| Cut 2 (multiples moved into stage 1) | **33.46 MHz** (29.89 ns) whole design; pricing alone 30.90 | [07](07-clock-fix.md) §4 |
| 10 placement seeds | 31.63 / 32.44 / 34.64 MHz (min / median / max) | [07](07-clock-fix.md) §6 |
| Orders | `make verify` 10/10 before and after | [07](07-clock-fix.md) §5 |
| Latency | 9 → 10 cycles (`basic`: min 9, median 10, max 11) | [07](07-clock-fix.md) §5 |
| Latency in time (calculated) | 9 × 53.08 ≈ 478 ns → 10 × 29.89 ≈ 299 ns | [07](07-clock-fix.md) §1 |
| Cost | +674 flip-flops (7,166 → 7,840), 9% of the chip | [07](07-clock-fix.md) §1 |

### Q2: the two order books

| | C++ (Assignment 1, `app/market_data/book.cpp`) | FPGA (`order_table.sv` + `book.sv`) |
|---|---|---|
| Order lookup by ref | Flat array of 2²⁰ entries × 16 bytes = **16 MB**; ref = index | Block RAM, **4,096 entries**, slot = ref mod 4,096, plus a tag; 28 of 208 block RAMs |
| Price levels | A ladder: one slot per tick up to $2,000, **200,000 slots per side** (8 bytes each, 1.6 MB per side) | **Best 16 levels per side**, sorted, in flip-flops |
| Finding a level | Index by price ÷ tick: one memory access | **Compare against all 16 at once** |
| When the best level empties | Linear scan of the ladder from the old best: a loop of varying length | Every worse level moves up a slot, in the same cycle |
| Reading the top of book | A cached best bid/ask | Slot 0, wired straight to the output: free |
| Time per update | Varies (scan length, cache) | **Fixed:** 1 cycle per update, 2 per item |
| Cost / size | Megabytes of memory | **12,330 LUTs**: 64% of the design's logic, 42.87 MHz |
| When capacity runs out | Throws (ref ≥ 2²⁰ or price out of range) | Sticky `book_overflow` / `unknown_order`, then halt |
| Assignment 1 note | Your critique suggested a production version needs "a ring buffer indexed by the reference modulo its size" | That's the FPGA order table: mod 4,096, with a tag to detect collisions |

**Chip budget** (from `make timing`): 83,640 LUTs, 83,640 flip-flops, 208 block RAMs of 18 Kbit (about 470 KB in total), 156 multipliers.

---

## 2. One-page version (about 690 words)

Write your own version from this. It includes optional additions 1, 2 and 3 from section 3 (about 130 words). Without them it was 556 words and left about 20% of the page empty, so a full page holds roughly 695 words at the template's 11 pt and 1-inch margins. At 688 words this is **right at the limit**. If your version spills onto a second page, use the trims in section 3.

**Explain the change you made and how it allows us to increase the clock frequency.**

The design's clock is limited by its slowest register-to-register path, because every register shares one clock. `make timing` showed that pricing was the only module under 30 MHz: 18.88 MHz on its own, and 18.84 MHz for the whole design. Every other module ran at 42.76 MHz or more. nextpnr's critical-path report showed why: pricing does its whole calculation in one cycle, one step after another. It computes the spread, the spread in ticks, S × bid size, fifteen comparisons to find fair value's tick, then the tick prices and the credit. In total that's 53 ns across 78 cells, and the two "keep the last comparison that holds" chains alone take about 33 ns. I split pricing into two pipeline stages, with a register after the multiply, the point closest to halfway. My first cut reached only 26.56 MHz: the fifteen multiples k × total size had been computed in parallel, off the critical path, and the cut moved them in front of the comparisons. Computing them in stage 1 as well, and storing all fifteen in the new register, made stage 2 start directly at the comparisons. The whole design now runs at 33.46 MHz, and between 31.6 and 34.6 MHz across ten placement seeds, so it's above 30 MHz for every placement. The arithmetic is unchanged and pricing keeps no state between items, so `make verify` still passes for all ten scenarios. The cost is one more cycle of latency, 10 instead of 9, and about 670 flip-flops. Each cycle is now much shorter, though, so an order leaves after about 299 ns instead of 478 ns. Throughput is unchanged, because items still arrive at most every two cycles. I chose pipelining over the alternatives. A divider for the microprice would be larger and slower still. A third stage would add another cycle without being needed. A multicycle-path constraint isn't part of this flow, and would depend on the merge never sending items faster. Pricing's second stage is still the slowest path. Its fifteen comparison results are always ones followed by zeros, so the boundary could be found in one step, as the book does, instead of a chain of fifteen. After pricing, the next limit is about 42 MHz (the quote manager and the book).

**Explain how your implementation of the order book differs from the C++ implementation of the order book. How does the implementation of each order book play to the strengths of the respective platform?**

The C++ book keeps every price. A ladder with one slot per tick, 200,000 per side, holds each level's size, and a 16 MB array indexed directly by order reference holds each order. Finding a level or an order is a single memory access. When the best level empties, the book scans the ladder for the next non-empty tick. This plays to the CPU's strengths: memory is plentiful and cheap, caches make nearby accesses fast, and a loop of varying length is cheap when it's usually short. The simulator's exchange book goes further still: a `std::map` of price levels, each holding a list of individual orders in time priority. That design relies on dynamic allocation and pointers, which an FPGA doesn't offer.

The FPGA book keeps only the best 16 levels per side, sorted, in flip-flops, and the per-order state lives separately in a 4,096-entry block RAM. Every update is compared with all 16 levels at once. Each level then takes its new value from itself, a neighbour or the new level, so a size change, an insert or a delete all finish in one cycle, and an item always takes exactly two. Reading the top of book costs nothing: it's slot 0, wired to the output. This plays to the FPGA's strengths, parallel logic and fixed timing, and avoids its weaknesses. Storage is scarce (the whole chip has about 470 KB of block RAM), a block RAM allows one access per cycle, and a scan of varying length would make a long, slow path. The price is limited capacity and area. A 17th level, or two orders sharing a table slot, can't be handled, so they raise sticky errors and the quote manager halts, where the C++ book would just continue. The 16-level book alone uses 12,330 LUTs, 64% of the design's logic, to buy that one-cycle update.

---

## 3. Optional additions for the remaining space

With your draft, about 20% of the page is left: roughly 110–130 words. Spend it on what the professor is most likely to probe ("why this and not another?", "how do you know?").

| # | Add to | What it covers | Words | Value |
|---|---|---|---|---|
| **1** | Q1 | Why this fix, not another | ~40 | **High:** the professor's favourite question |
| **2** | Q2 | One line on the simulator's exchange book, in case Q2 means that one | ~35 | **High:** covers the ambiguity |
| **3** | Q1 | What limits the clock now, and what's next | ~30 | Medium |
| 4 | Q2 | The link to the Assignment 1 critique | ~35 | Medium: invites questions on Assignment 1 |
| 5 | Q1 | How you know it isn't noise | ~25 | Low: the 10-seed range already says it |

**Suggested: 1 + 2 + 3, about 105 words. These are now included in the one-page version (section 2).**

**If it spills onto a second page, trim in this order:**
1. In #3, drop "Its fifteen comparison results … a chain of fifteen." Keep the first and last sentences (−30 words).
2. In #1, shorten to: "I chose pipelining over a divider (larger and slower) or a third stage (an extra cycle, not needed)." (−25 words)
3. In Q2, drop "Reading the top of book costs nothing: it's slot 0, wired to the output." (−14 words)

**1, Q1, why this fix:**
> I chose pipelining over the alternatives. A divider for the microprice would be larger and slower still. A third stage would add another cycle without being needed. A multicycle-path constraint isn't part of this flow, and would depend on the merge never sending items faster.

These alternatives were *reasoned about*, not built and measured. If asked, say so; building one is optional experiment 5b.

**2, Q2, the exchange's book** (after the C++ paragraph):
> The simulator's exchange book goes further still: a `std::map` of price levels, each holding a list of individual orders in time priority. That design relies on dynamic allocation and pointers, which an FPGA doesn't offer.

**3, Q1, what's next** (at the end):
> Pricing's second stage is still the slowest path. Its fifteen comparison results are always ones followed by zeros, so the boundary could be found in one step, as the book does, instead of a chain of fifteen. After pricing, the next limit is about 42 MHz (the quote manager and the book).

Only include #3 if you can explain "ones followed by zeros" out loud: it's the `is_better` / `is_new` mask from `book.sv`.

**4, Q2, the Assignment 1 link** (alternative to #2):
> In Assignment 1 I noted that a production version of the C++ order table would need a ring buffer indexed by the order reference modulo its size. The FPGA's 4,096-entry table is exactly that, with a tag so that a collision is detected instead of silently corrupting the book.

**5, Q1, noise:**
> `make timing` is deterministic: thirty runs gave identical results. The variation comes from placement changing when the design changes, about ten percent here, far less than the seventy-eight percent gain.

---

## 4. Long version

### Q1, extra points if there's room or the professor asks

- **How the cut point was chosen:** the time per step was read from nextpnr's critical-path report, each hop mapped to its source line. The multiply ends at 25.6 ns of 53, the closest point to halfway.
- **Why the first cut fell short is the main lesson:** a critical-path report only shows work *on* the path. Work done in parallel off the path (the 15 multiples) can land on it once a register moves.
- **Why it's correct, in full:**
  1. same arithmetic, line for line;
  2. no state between items;
  3. items at least 2 cycles apart (the merge), so the middle register is always free;
  4. simulated time is frozen while the FPGA works, so one extra cycle can't change any order;
  5. `credit` only changes while the pipeline is idle.
- **Noise:** `make timing` is deterministic (30 identical runs). The variation comes from placement when the design changes: about 10% across seeds for the whole design, and 30.90 vs 33.46 MHz for the same logic placed in two contexts.
- **What next:** stage 2 is still the limit. The 15 comparison results are always 1s then 0s, so k can be found in one step (the book's `is_new` trick) instead of a chain of 15. After pricing, the next ceiling is about 42 MHz (quote_manager, book).
- **Rejected alternatives:**
  - a divider: larger and slower;
  - a third stage: not needed, and another cycle;
  - a multicycle-path constraint: not in this flow, and fragile.

### Q2, extra points

- **Why the FPGA splits the book in two:**
  - **Per-order state** needs many entries and one lookup per message, so it goes in block RAM: large, but one read per cycle, a cycle late.
  - **Price levels** must be searched and kept sorted on every update, so they go in flip-flops: every level visible at once.
  - The C++ `Book` class holds both, because CPU memory serves both access patterns well enough.
- **Why compare all 16 levels at once, not loop:** a loop is a chain, and its path grows with the number of levels. Parallel comparison keeps the path at one comparison plus one small choice per slot. The cost is area: 16 comparators and 16 adders per side.
- **Why 16 levels:** each level adds a comparator, an adder, a choice and about 65 flip-flops per side, and lengthens the OR across the matches. More levels cost area and clock speed. 16 covers the top of a normal book.
- **Halt vs refill:** once a level is dropped, the book can't know when it should reappear. Real systems back the 16 registers with a full-depth store and refill from it (book.sv's own comment). Here, halting is the safe choice.
- **The two order tables mirror the A1 critique:** the C++ array needs 2²⁰ × 16 bytes and stops at ref 2²⁰. The FPGA table is the "ring buffer indexed by ref modulo its size" that the critique recommended, with a tag so a collision is detected rather than silently corrupting the book.
- **Determinism:** the FPGA book takes 2 cycles per item whatever the book looks like. The C++ book's time depends on how far the scan goes and on the cache.

---

## 5. AI-use statement: the facts to include

The statement must be in your own words. These are the facts of how it was done, so it's accurate:

- **Tool:** Claude Code (Claude Opus 5.5), in VS Code.
- **Understanding:** explained the design doc, the code and the hardware concepts, in a section-by-section walkthrough with check questions.
- **Code:**
  - for each of the four modules and the pricing change, Claude explained the spec and the tests, and you predicted the logic first;
  - Claude then proposed the code in chat;
  - **you pasted it yourself** (Claude didn't edit the code files), and went through it line by line;
  - you ran the unit tests, `make verify` and `make timing` in your own terminal.
- **The clock fix, who decided what:**
  - The assignment only said to change "one of the other modules"; it named neither the module nor the method.
  - Claude predicted pricing and pipelining from reading the code at the very start, before any measurement. `make timing` then confirmed pricing as the only module under 30 MHz.
  - You agreed to the approach, and **predicted the cut point** (after the multiply) and the expected clock (about 35 MHz) from the measured step times.
  - Claude read the timing reports and nextpnr's critical-path logs, found why the first cut fell short, proposed the second, and suggested the seed runs to measure the placement noise.
  - The alternatives (divider, third stage, multicycle path) were reasoned about, not built.
- **Notes and git:** Claude wrote the study notes in `notes/` and made the commits, each with your approval.
- **Write-up:** Claude wrote reference text with sourced numbers (this file); you wrote the submitted text yourself, using it as reference.
- **Collaboration with classmates:** fill in yourself (in Assignment 1 this was left as a placeholder).

---

## 6. Checklist before submitting

- [ ] `\studentname` and `\netid` filled in (the template has `Your Name` and `abc1234`). Your Assignment 1 PDF used `psp8502`.
- [ ] Font size, margins and structure unchanged (the template's rule).
- [ ] The AI statement on its own page; the write-up after the page break **fits on one page**.
- [ ] Every number matches this file's facts sheet.
- [ ] Compiled to PDF (Overleaf; there's no LaTeX on this Mac).
- [ ] Where and in what form to submit the code and PDF: check the course page.
