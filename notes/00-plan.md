# Assignment 2: the plan

*Written 2026-10-28. Assignment 1's notes are in [../../assignment01/notes/](../../assignment01/notes/).*

## Contents

1. [Goal](#1-goal)
2. [How understanding is built](#2-how-understanding-is-built)
3. [Git layout](#3-git-layout)
4. [The phases](#4-the-phases)
5. [Sessions and time](#5-sessions-and-time)
6. [Open items](#6-open-items)

---

## 1. Goal

Two goals, equally important:

1. **A working submission:**
   - the four modules;
   - a clock above 30 MHz;
   - the one-page write-up.
2. **Being able to defend every part of it** in a 15–20 minute interview. The professor reads the write-up word by word, and asks about each point:
   - where did you see it?
   - how did you find out?
   - why does it happen?
   - how does your change fix it?
   - why this and not something else?

---

## 2. How understanding is built

These four habits run through every phase.

1. **Decision cards.** Every choice we make gets a card in that phase's notes file:

   | Field | What goes in it |
   |---|---|
   | What we did | One sentence |
   | Why | The mechanism: what happens in the hardware or the code |
   | Evidence | A number or test result, and exactly where it came from |
   | Alternatives | What else we could have done, and why we didn't |
   | Trade-off | What it costs, and where it stops working |
   | Likely questions | What the professor might ask about it |

2. **Explain-back.** At the end of each phase:
   - you explain it in your own words, without notes, in 2–3 minutes;
   - I ask 5 professor-style follow-up questions;
   - anything shaky goes onto the interview-prep list.

3. **Evidence, not claims.** Every number comes from a specific test, run or report, and the note says which one. Calculated numbers, such as latency in nanoseconds (cycles × clock period), are labelled as calculated.

4. **Try the alternatives.** For the big "why not X?" questions, we build X on a throwaway branch and measure it. Then the answer is a measurement, not an opinion.

---

## 3. Git layout

| Branch or tag | Holds | Rule |
|---|---|---|
| `main` | Starter code, the four modules, notes, and the final write-up | Notes are committed only here |
| tag `baseline` | The commit where the four modules are done and `make verify` passes | Every fix and experiment starts from here, so they all share the same starting point |
| `fix-pricing-pipeline` | The clock fix: pricing split into stages | Merged into `main` once chosen |
| `fix-pricing-restructure` | Optional alternative fix | Kept for comparison |
| `exp-*` | Experiments (Phase 5b) | Never merged |

The four modules go straight on `main` because they're required work, not a variant. This avoids Assignment 1's problem of notes commits ending up inside a fix branch's history.

---

## 4. The phases

### Phase 0: Setup (0.5–1 h) → `notes/02-build-setup.md`

1. **Toolchain:** `make tools` (500–750 MB download).
2. **Build:** set `SDKROOT` (the Mac fix from Assignment 1), then `make`. The starter should build: the four unfinished modules compile, they just do nothing.
3. **Starting point:** record what `make test-holes` and `make verify` report now. Most tests should fail. `make verify` should fail too: the empty parser lets no market data through, so no orders come out.
4. **First timing run on the starter:** `make timing`. Is pricing already the slowest module, and below 20 MHz? This is the metric, seen before we change anything.

**Done when:** the build works and the starting numbers are written down.

### Phase 1: Understand the design (2–3 h) → `notes/01-project-overview.md`

- **What changed from Assignment 1:**
  - the hot path moved from C++ onto the FPGA;
  - the CPU only runs the timer (the cold path);
  - latency is counted in clock cycles, not wall-clock time.
- **Hardware terms, each defined with an example from this code:**
  - clock cycle;
  - register (flip-flop);
  - combinational logic;
  - critical path;
  - max clock frequency;
  - LUT;
  - block RAM;
  - multiplier (DSP);
  - pipeline stage;
  - latency vs throughput;
  - initiation interval;
  - synthesis, place and route;
  - Verilator.
- **The pipeline:** each module, what goes in and out, how many cycles it takes, and why.
- **The modules already written:**
  - report parser;
  - merge;
  - order table;
  - pricing;
  - quote manager;
  - register bank.

  We read each one, because the interview can ask about any of them.
- **Why the FPGA splits the order book in two:**
  - an order table in block RAM;
  - a 16-level book in registers.

  The C++ version used a single `Book` class.

**Explain-back:** walk one market data message through the pipeline, on paper.

### Phase 2: Write the four modules (3–5 h) → `notes/05-modules.md`, on `main`

Easiest first, one commit per step:

1. Offset constants in `messages_pkg.sv`.
2. Market data parser, then its unit test.
3. Sequence check, then its unit test.
4. Order encoder, then its unit test.
5. Book (`apply_update`), then its unit test.
6. `make verify`: all 10 scenarios PASS. Tag `baseline`, push.

For each module:
1. I explain the spec and what its tests check.
2. You predict the logic before I write it.
3. We go through the code line by line.
4. Decision cards.

Main decision cards:

| Module | Decisions to understand |
|---|---|
| Parser | Why a whole message is decoded in one cycle (a 512-bit bus, and fixed offsets are just wires); why missing fields are zero; unknown message types |
| Sequence check | Why the gap is sticky; why a repeated number counts as a gap; why expected becomes number + 1 even after a gap |
| Encoder | Replace's two tokens (existing at byte 1, replacement at byte 9); zero padding |
| Book | Comparing against all levels at once instead of looping; why 16 levels; inserting into a full side; why one update per cycle, so a replace takes 2 cycles and the pipeline accepts an item only every 2 cycles |

**Done when:** `make test-holes` and `make verify` both pass, with zero build warnings.

### Phase 3: Watch it run (1.5–2.5 h) → `notes/03-pipeline-walkthrough.md`, `notes/04-scenarios.md`

- **One message, cycle by cycle:** follow a message from `basic` through the waveform (GTKWave), module by module. Confirm:
  - 9 cycles for market data;
  - 8 for an execution report;
  - the bid order in one cycle, the ask in the next.
- **The new scenarios:** `book_overflow`, `table_collision`, `wide_spread`. What happens, and which module causes it.
- **Why `loss` and `position` differ from Assignment 1:** prices diverge by 1–2 cents after a timer tick.
- **The five unchanged scenarios** (`basic`, `empty_side`, `gap`, `quiet`, `sweep`): link to Assignment 1 notes 03–06.

### Phase 4: Measure the baseline (0.5–1 h) → `notes/06-timing-baseline.md`

- **Three clean timing runs.** Delete `build/timing` before each one, because `make timing` reuses its results until an RTL file changes.
- **Record:**
  - whole-design max frequency;
  - each module's max frequency;
  - where the critical path starts and ends;
  - logic vs routing time;
  - LUTs, flip-flops, block RAMs, multipliers.
- **Noise floor:** the spread between the three runs.
- **The critical path:** read the report hop by hop and explain why that path is long.

### Phase 5: The clock fix (1–2 h) → `notes/07-clock-fix.md`, branch `fix-pricing-pipeline`

1. Split pricing into two stages. Try at least two places to cut, and keep the one that balances the two halves best.
2. Check:
   - `make test-holes`;
   - `make verify` (orders must be identical);
   - three clean timing runs;
   - latency in cycles, from `build/market_maker`'s output.
3. Decision cards:
   - why pipelining;
   - why this cut point;
   - why it's safe: pricing keeps no state between items, and items arrive at least 2 cycles apart;
   - the cost: one extra cycle and extra flip-flops, and why it's still faster in nanoseconds;
   - which module is now the slowest;
   - why not the alternatives.
4. Merge into `main` once chosen.

### Phase 5b: Experiments (optional, 2.5–5 h, mostly waiting for `make timing`)

Each answers a likely "why not X?" with a measurement. Each lives on its own `exp-*` branch and is never merged.

| Experiment | Question it answers |
|---|---|
| Restructure pricing without an extra cycle | Why add a cycle instead of making the logic faster? |
| Book applying both updates of a replace in one cycle | Why does a replace take two cycles? The design doc says "several times larger and slower", and we measure it |
| Book with 8, 16 and 32 levels | Why only 16 levels? What does depth cost? |
| Book written as a loop instead of in parallel | Why the parallel style? |

If time is short, do the first two.

### Phase 6: Write-up (1.5–2.5 h) → `notes/08-writeup-reference.md`, `docs/write-up.tex`

1. I write reference answers to both prompts, a long version and a one-page version, with every number sourced.
2. You write your own draft in `write-up.tex`.
3. I review facts and wording, and check it fits on one page.
4. The AI-use statement page.
5. Compile on Overleaf (there's no LaTeX on this Mac), then commit the `.tex` and the PDF.

### Phase 7: Interview prep (3–4 h) → `notes/09-interview-prep.md`

- **Numbers to know by heart.**
- **The answer format from Assignment 1:**
  1. the claim;
  2. the mechanism;
  3. the evidence;
  4. the method;
  5. the fix and its trade-off.

  30–60 seconds per answer.
- **A question bank, grouped by topic:**
  - the pipeline;
  - each module you wrote;
  - the book;
  - the clock fix;
  - alternatives;
  - FPGA book vs C++ book;
  - FPGA basics;
  - AI use.
- **A glossary** of every term in the write-up.
- **Mock interviews:**
  - I play the professor: I read your write-up word by word and ask follow-ups;
  - you answer without notes;
  - two or three rounds, the last one timed at 15 minutes.

---

## 5. Sessions and time

| Session | Phases | Time |
|---|---|---|
| 1 | 0 Setup, 1 Understand | 2.5–4 h |
| 2 | 2 Modules | 3–5 h |
| 3 | 3 Watch it run, 4 Baseline, 5 Fix | 3–5.5 h |
| 4 | 5b Experiments (optional) | 2.5–5 h |
| 5 | 6 Write-up | 1.5–2.5 h |
| 6 | 7 Interview prep and mocks | 3–4 h |
| Day before the interview | Final timed mock, numbers review | 1 h |

**Total:** about 13–21 h core, most likely around 17 h, plus 2.5–5 h for the optional experiments. These are estimates, not measurements.

---

## 6. Open items

- The deadline and the interview date.
- Where and in what form to submit: an archive or the repo link, and the PDF name. Check the course page.
