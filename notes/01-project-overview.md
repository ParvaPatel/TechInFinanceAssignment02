# Assignment 2: project overview and study notes

*Written 2026-10-28. Previous: [00-plan.md](00-plan.md).*

## Contents

1. [What the application is](#1-what-the-application-is)
2. [Hardware terms](#2-hardware-terms)
3. [The pipeline](#3-the-pipeline)
4. [The modules that are already written](#4-the-modules-that-are-already-written)
5. [Why the order book is split in two](#5-why-the-order-book-is-split-in-two)
6. [The strategy, and what changed from Assignment 1](#6-the-strategy-and-what-changed-from-assignment-1)
7. [Running it](#7-running-it)
8. [Explain-back questions](#8-explain-back-questions)

Sources: [docs/assignment.pdf](../docs/assignment.pdf), [docs/design.pdf](../docs/design.pdf), and the code in [rtl/](../rtl/) and [app/](../app/). Facts that still need a run to confirm are marked **(to confirm)**.

---

## 1. What the application is

### In short

It's the same market maker as Assignment 1, with the same simulator, scenarios and strategy. The difference is where the decisions are made:

- **Assignment 1:** a C++ program made every decision.
- **Assignment 2:** the **hot path** (everything from a message arriving to an order leaving) is a hardware design for an FPGA, written in SystemVerilog in `rtl/`. There's no physical board. Verilator turns the design into C++, and the same simulator drives it.

The CPU still runs the **cold path**: once per timer tick, it reads a few values from the FPGA and writes back two settings.

### What moved where

| Job | Assignment 1 (C++) | Assignment 2 | Who writes it |
|---|---|---|---|
| Decode market data | C++, `memcpy` into structs | `market_data_parser` | **you** |
| Detect missed feed messages | C++ check | `sequence_check` | **you** |
| Decode execution reports | C++ | `report_parser` | given |
| Put both streams in one order | Not needed (one thread) | `merge` | given |
| Remember every order by its ref | `Book::orders_`, a flat array of 2²⁰ entries | `order_table`, block RAM with 4,096 entries | given |
| Price levels and best bid/ask | `Book`: one ladder slot per tick, plus a cached best | `book`: the best 16 levels per side, in registers | **you** |
| Fair value and quote prices | C++ with a division (`CalcMicroprice`) | `pricing`, with no divider | given (likely the module to change) |
| Our quotes, position, cash, limits | C++ | `quote_manager` | given |
| Encode orders | C++ | `order_encoder` | **you** |
| Volatility, credit, loss limit | C++ | CPU cold path ([app/market_maker.cpp](../app/market_maker.cpp)) | given |

### How a run works

1. The simulator delivers one message to `MarketMaker` ([app/market_maker.cpp](../app/market_maker.cpp)).
2. `MarketMaker` passes the raw bytes to the board, `Fpga` ([app/fpga.cpp](../app/fpga.cpp)), without reading them.
3. `Fpga` copies the message onto a 512-bit input and sets its valid signal for **one cycle**.
4. `Fpga` keeps the clock running until no order has come out for 64 cycles.
5. It returns every order that came out, each with the number of cycles since the message went in.
6. `MarketMaker` sends those orders to the exchange.

Simulated time stands still while this happens, so the number of cycles never changes which orders are sent, or when.

**Cold path (every timer tick, `OnTimer`):**
- reads the `mid`, `position` and `cash` registers;
- updates volatility;
- writes the `credit` register;
- writes the `halt` register if the loss is over the limit.

### How speed is measured

| | Assignment 1 | Assignment 2 |
|---|---|---|
| What is counted | Wall-clock nanoseconds per message | Clock cycles per order |
| Noise | Large: up to 4× between identical runs | None in cycles: the same input always takes the same number of cycles |
| To get time | Measured directly | Cycles × clock period |
| Where each part comes from | The timer | Cycles from `build/market_maker`'s output; the clock period from `make timing` |

`make timing` itself varies by a few percent between runs. That comes from where the tools place the logic on the chip, not from the design.

---

## 2. Hardware terms

| Term | Meaning | Example in this code |
|---|---|---|
| **Clock, cycle** | A signal that ticks at a fixed rate; one tick is one cycle. Everything happens in step with it. | `Fpga::Tick` sets `clk` to 0, then to 1 |
| **Rising edge** | The moment the clock goes from 0 to 1. Every register updates at that instant. | `always_ff @(posedge clk)` |
| **Register (flip-flop)** | One bit of memory. It takes a new value only on the rising edge and holds it for the whole cycle. | `item <= item_next;` |
| **Combinational logic** | Logic with no memory: gates whose output follows their inputs within the same cycle. | Every `always_comb` block |
| **The `_next` pattern** | Each module computes next cycle's values in `always_comb` (`x_next`), then stores them in `always_ff` (`x <= x_next`). | `market_event_next` → `market_event` |
| **Registered output** | A module's outputs come straight from registers. A signal never passes through two modules' logic in one cycle. | Every module here |
| **Valid signal** | A 1-bit signal that is high exactly in the cycles when the data next to it means something. | `market_event_valid` |
| **Path** | A route from one register, through combinational logic, to another register. | Pricing's input registers → arithmetic → output register |
| **Critical path** | The slowest path in the design. The signal must get through it within one cycle, so it sets the shortest possible clock period. | Expected to be inside `pricing` **(to confirm)** |
| **Max clock frequency (fmax)** | 1 ÷ (shortest possible clock period). | 50 ns → 20 MHz; 33.3 ns → 30 MHz |
| **Latency** | How many cycles from an input to the output it causes. | 9 cycles from market data to order (design doc) |
| **Throughput, initiation interval (II)** | How often a new item can enter. II = 2 means one item every 2 cycles. | After the merge, II = 2, because the book needs 2 cycles for a replace |
| **Pipeline, pipeline stage** | Work split across cycles, with registers between the parts. Each part works on a different item at the same time, like an assembly line. | The whole design: 10 register stages from message to order |
| **Sticky flag** | A bit that stays set once set, until reset. | `sequence_gap`, `unknown_order`, `book_overflow` |
| **Latch** | Accidental memory, created when an `always_comb` block doesn't assign a signal on every path. Verilator rejects it. | Why every `always_comb` here starts by assigning defaults |
| **Packed struct** | A named bundle of bits. The first field sits in the highest bits. | `market_data_event_t`; the unit tests use these bit positions |
| **LUT (lookup table)** | The FPGA's basic logic cell. On this chip, a LUT can compute any function of 4 input bits. All combinational logic becomes LUTs. | `make timing` reports "logic cells (LUTs)" |
| **Carry chain** | Dedicated fast wiring for adders and comparisons. | 32- and 64-bit adds and compares |
| **Block RAM** | Memory blocks built into the chip. One read and one write per cycle per port; the read result arrives a cycle later. | The order table's 4,096 entries |
| **Multiplier (DSP)** | Built-in 18 × 18-bit multiplier blocks. | Pricing's `spread_ticks × bid_size`; the quote manager's `shares × price` |
| **Routing** | The wires between cells. Often about half of a path's delay. | `make timing` reports "ns logic, ns routing" |
| **Synthesis (Yosys)** | Turns the SystemVerilog into a netlist: a list of LUTs, flip-flops, block RAMs and multipliers, and how they connect. | First step of `make timing` |
| **Place and route (nextpnr)** | Chooses where on the chip each cell goes, connects them with wires, then computes the timing. | Second step of `make timing` |
| **Out-of-context** | Each module is timed on its own, with a register added on every input. | [timing/wrappers.sv](../timing/wrappers.sv) |
| **Verilator** | Compiles the design into a C++ class for simulation. Here, every warning stops the build. | `make` builds `build/market_maker` with it |
| **The chip** | Lattice ECP5 LFE5U-85F, speed grade 6 (as on the ULX3S board). | What `make timing` targets |

---

## 3. The pipeline

```
 market data (512 bits)               execution report (512 bits)
        │                                       │
 market_data_parser   1 cycle            report_parser   1 cycle
        │ market_data_event_t                   │ report_event_t
 sequence_check       1 cycle                   │
        │ pipeline_item_t                       │
        └────────────────► merge ◄──────────────┘   1 cycle or more
                             │ pipeline_item_t       (one item every 2 cycles)
                        order_table   2 cycles
                             │ book_item_t
                           book       2 cycles ──── mid ───► register_bank ◄─► CPU
                             │ pricing_item_t                  │      │
                          pricing     1 cycle ◄─── credit ─────┘      │
                             │ quote_item_t                           │
                       quote_manager  1 cycle (bid), 2 (ask) ◄─ halt ─┘
                             │ order_request_t   ── position, cash ──► register_bank
                       order_encoder  1 cycle
                             │ 512 bits
                          orders to the exchange
```

| Module | In → out | Cycles | Its job |
|---|---|---|---|
| `market_data_parser` | 512-bit message → `market_data_event_t` | 1 | Pick each field out of the message at its fixed byte offset |
| `sequence_check` | event → `pipeline_item_t` | 1 | Flag a missed message (sticky) |
| `report_parser` | 512-bit report → `report_event_t` | 1 | The same as the parser, for reports |
| `merge` | two streams → one | 1 or more | One ordered stream; market data first; at most one item every 2 cycles |
| `order_table` | `pipeline_item_t` → `book_item_t` | 2 | Turn "order 1234 lost 50 shares" into "50 shares leave price P on side S"; track which orders are ours |
| `book` | `book_item_t` → `pricing_item_t` | 2 | Keep the best 16 price levels per side; output the top of the book |
| `pricing` | → `quote_item_t` | 1 | The bid and ask we want, from the microprice, with no division |
| `quote_manager` | → `order_request_t` | 1 (bid), 2 (ask) | Decide whether to enter, replace or cancel; track position and cash; halt |
| `order_encoder` | → 512-bit message | 1 | Write each field at its fixed byte offset |
| `register_bank` | CPU bus | — | Five registers the CPU reads or writes |

### Latency

- **Market data:** 1 + 1 + 1 + 2 + 2 + 1 + 1 + 1 = **10 register stages**. `Fpga` counts from the cycle the message is presented, as cycle 0, so the order appears at cycle **9**. This is the design doc's figure.
- **Execution reports:** they skip the sequence check, so 9 stages, and the order appears at cycle **8**.
- **(to confirm in Phase 3 with the waveform.)**

### Items change type as they travel

Each stage passes on only what later stages need:

| Type | What it carries |
|---|---|
| `pipeline_item_t` | The event (market data or report), plus the error flags |
| `book_item_t` | Up to 2 level updates, the report (if it is one), and the flags. The market data event itself is dropped here |
| `pricing_item_t` | The top of the book, the report, and the flags |
| `quote_item_t` | The bid and ask we want, whether we can quote, the report, and the flags |

### Error flags

| Flag | Set by | Meaning | Sticky? |
|---|---|---|---|
| `sequence_gap` | sequence check | A market data message was missed | yes |
| `unknown_order` | order table | The feed mentioned an order the table doesn't hold | yes |
| `book_overflow` | book | A side needed more than 16 levels | yes |
| `book_invalid` | book | After this item, a side is empty or the book is crossed | no, applies to this item only |

The three sticky flags make the quote manager **halt**: cancel everything, and never quote again. The reason in each case: after that problem, the book can no longer be trusted.

---

## 4. The modules that are already written

These matter because the interview can ask about any part of the pipeline, not only the parts you wrote.

### `report_parser` ([rtl/report_parser.sv](../rtl/report_parser.sv))

- A `case` on the type byte.
- Each field is a fixed slice of the 512-bit input. Slicing costs no logic, because it's just wires.
- An unknown type produces no event.
- Your market data parser follows the same pattern.

### `merge` ([rtl/merge.sv](../rtl/merge.sv))

- **One stream:** combines market data and reports. When both are waiting, market data goes first, because tick-to-trade is measured on market data.
- **One item every 2 cycles:** `can_send = !item_valid`, meaning "an item left last cycle, so wait one".
- **Buffering:** a one-entry buffer per stream holds what can't leave yet.
- **Why one entry is enough:**
  - the shortest message is 26 bytes;
  - a 64-bit network link carries 8 bytes per cycle;
  - so each stream delivers at most 1 message every 4 cycles;
  - two streams therefore deliver at most 2 items per 4 cycles, exactly what the merge sends.
- **Overflow:** if messages ever arrive faster, an item is lost and the sticky `overflow` output goes high. The simulator never triggers this, because it hands over one message at a time.

### `order_table` ([rtl/order_table.sv](../rtl/order_table.sv))

- **Storage:** block RAM with 4,096 entries. An entry is chosen by the low 12 bits of the order ref ("direct-mapped").
- **Tags:** each entry also stores the other 52 bits of the ref. A different order that lands in the same entry then isn't mistaken for this one.
- **Collisions:** each ref has only one possible entry. If an order rests while 4,096 newer orders arrive, its entry gets overwritten, and a later message about it sets `unknown_order`. The `table_collision` scenario tests exactly this.
- **Two cycles:**
  1. read the entry;
  2. update it and produce the level updates.
- **Write forwarding:** if an item reads an entry in the same cycle the previous item writes it, the RAM would return the old value. The table uses the value being written instead.
- **Our own orders:** an Accepted or Replaced report marks a ref as ours. Its shares are taken back out of the book, or never added if the report came before the feed's Add.

### `pricing` ([rtl/pricing.sv](../rtl/pricing.sv))

- **Fair value is the microprice:** (B × ask size + A × bid size) ÷ (bid size + ask size), where B is the best bid and A the best ask.
- **No divider:** a divider is far too large and slow. We only need the ticks just below and just above fair value:
  1. Let S be the spread in ticks. It's found with 16 comparisons, one per possible S.
  2. The tick at or below fair value is B + k ticks, where k is the largest whole number with k × (bid size + ask size) ≤ S × bid size. It's found with 15 comparisons, one per possible k.
  3. bid = (tick at or below fair value) − credit; ask = (tick at or above fair value) + credit.
- **No quote when:**
  - the book is invalid;
  - the spread is over 16 ticks;
  - or the bid would be ≤ 0.
- **Why it's probably the slowest module (to confirm in Phase 4):** all of it happens in one cycle, one step after another:
  1. subtract;
  2. 16 compares;
  3. a multiply;
  4. 15 wide compares;
  5. pick the largest that holds;
  6. × 100;
  7. add;
  8. compare and subtract with the credit.

### `quote_manager` ([rtl/quote_manager.sv](../rtl/quote_manager.sv))

For each item:
1. **Apply the report**, if the item is one: Accepted/Replaced makes the in-flight request our resting order; Executed changes position, cash and open shares; Rejected/Canceled clears what it names.
2. **Decide**, for each side, whether to enter a new order or replace the existing one:
   - only if pricing can quote;
   - only if no request is already in flight on that side;
   - only if the position limit allows it: no buy that could take the position above +500 shares, no sell below −500.
3. **Send**, with tokens numbered 1, 2, 3, ….

Details:
- **One request per cycle:** the encoder takes one request per cycle, so the bid's request leaves in the item's first cycle and the ask's in the second.
- **Halt** (any sticky flag, or the CPU's halt register): permanent. A small state machine then sends one cancel per cycle: each side's resting order, and any request in flight.

### `register_bank` ([rtl/register_bank.sv](../rtl/register_bank.sv))

| Address | Register | Access | Meaning |
|---|---|---|---|
| 0 | credit | CPU writes | Half-spread, a whole number of ticks. Starts at 100 ($0.01) |
| 1 | halt | CPU writes | Nonzero: cancel everything and stop |
| 2 | position | CPU reads | Shares, signed |
| 3 | cash | CPU reads | Price units × shares, signed |
| 4 | mid | CPU reads | Bit 63: the book is valid. Low 32 bits: (B + A) ÷ 2 |

Reads are combinational: they take no clock cycle.

---

## 5. Why the order book is split in two

On the FPGA, the C++ `Book` class becomes two modules, because its two halves are used in very different ways:

| Half | Module | How it's used | Best home on an FPGA |
|---|---|---|---|
| Who and where: ref → side, price, shares, ours? | `order_table` | Look up one entry per message. Needs many entries (4,096) | **Block RAM:** large and cheap, but only one read and one write per cycle |
| How much at each price, and which is best | `book` | Every update must find its level and keep the list sorted, every cycle | **Registers:** every level visible at once, so all 16 can be compared in parallel |

Explaining how the FPGA book differs from the C++ one, and why, is write-up question 2. It gets its own note in Phase 6.

---

## 6. The strategy, and what changed from Assignment 1

The strategy is the same as Assignment 1:
- quote one bid and one ask, 100 shares each, around the microprice, each one credit away;
- position limit ±500 shares;
- loss limit $100: the CPU marks our position to the mid and writes halt if breached;
- halt on a sequence gap.

The assignment calls the rest "minor variations to account for the difference in platforms":

| | Assignment 1 | Assignment 2 | Why |
|---|---|---|---|
| Credit rounding | Rounded up to a whole price unit; then each quote rounded to the tick grid, away from fair value | Rounded **up to a whole tick** on the CPU; added to ticks next to fair value | The FPGA adds the credit to prices already on the tick grid, so the credit must be on the grid too ([app/volatility.h](../app/volatility.h)) |
| Widest spread quoted | Any | 16 ticks | One comparator per possible tick |
| Book depth | Every price | Best 16 levels per side; more → halt | Registers are scarce |
| Order table | 2²⁰ entries, no collisions | 4,096 entries; a collision → `unknown_order` → halt | Block RAM size |

**Scenarios, compared with Assignment 1:**

| Scenario | Compared with Assignment 1 | What to read |
|---|---|---|
| `basic`, `empty_side`, `gap`, `quiet`, `sweep` | Same file, same expected orders | Assignment 1 notes 03–06 |
| `loss`, `position` | Same file; prices differ by 1–2 cents from a timer tick onward | Likely cause below; confirmed in Phase 3 |
| `book_overflow`, `table_collision`, `wide_spread` | New | Phase 3 |

**Likely cause of the `loss`/`position` difference (to confirm in Phase 3):** the credit rounding. Both versions start with a credit of exactly 1 tick (100), so they quote identically. Once volatility pushes the credit above 1 tick, Assignment 2 rounds it up to a whole number of ticks, which gives slightly wider quotes. That's consistent with what the expected files show: in `loss`, the first changed order bids 99.94 in Assignment 2 vs 99.96 in Assignment 1.

---

## 7. Running it

The `export` line is the Mac build fix from Assignment 1; it's needed once per terminal window.

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
make tools
make
make test-holes
make verify
make timing
./build/market_maker sim/fixtures/basic.scn
./build/market_maker sim/fixtures/basic.scn --trace --waves
tools/oss-cad-suite/bin/gtkwave build/out/basic/waves.vcd
```

| Command | What it does |
|---|---|
| `make tools` | Downloads the pinned FPGA tools into `tools/` (once) |
| `make` | Builds `build/market_maker`: the design, compiled by Verilator, plus the simulator and `app/` |
| `make test-holes` | Unit tests for the four modules you write. Fast; run these first |
| `make verify` | Runs all 10 scenarios; each must send exactly the expected orders |
| `make timing` | Synthesis, then place and route. Prints the max clock frequency for the whole design and for each module. Takes a few minutes, and reuses its results until an RTL file changes |
| `build/market_maker <scenario>` | Runs one scenario. Writes `build/out/<name>/orders.txt` and prints the latency in cycles |
| `--trace` | Also writes every message to `trace.txt` |
| `--waves` | Also records every signal, every cycle, to `waves.vcd`, for GTKWave |

---

## 8. Explain-back questions

Answer these without notes, in your own words, about a minute each:

1. What runs on the FPGA, and what still runs on the CPU? Why is that split sensible?
2. What decides the max clock frequency of a design? Why does every module having registered outputs matter for it?
3. Walk a market data AddOrder from the 512-bit input to an EnterOrder coming out. Which modules does it pass, and why is it 9 cycles?
4. Why can the pipeline take only one item every two cycles after the merge? Why is a one-entry buffer per stream enough?
5. What's the difference between the order table and the book? Why is one in block RAM and the other in registers?
6. Which three errors halt the quote manager, and why does each make the book untrustworthy?
7. How does pricing find the quote prices without dividing?
8. Why do `loss` and `position` send slightly different orders than in Assignment 1?
