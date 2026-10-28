# Build setup on this Mac, and the starting point

*Written 2026-10-28. Previous: [01-project-overview.md](01-project-overview.md).*

## Contents

1. [Summary](#1-summary)
2. [How to build (every new terminal window)](#2-how-to-build-every-new-terminal-window)
3. [Problem 1: spaces in the folder path](#3-problem-1-spaces-in-the-folder-path)
4. [Problem 2: the linker error (same as Assignment 1)](#4-problem-2-the-linker-error-same-as-assignment-1)
5. [The starting point: tests and scenarios](#5-the-starting-point-tests-and-scenarios)
6. [The starting point: timing](#6-the-starting-point-timing)

---

## 1. Summary

| | Result |
|---|---|
| Toolchain | Verilator 5.053, Yosys 0.70, nextpnr-ecp5 0.11.1 (OSS CAD Suite 2026-10-14), 1.9 GB in `tools/` |
| Problem 1 | The original folder path had spaces, which broke Verilator and the Makefile. **Fix:** the project moved to `/Users/parva/NYU/SEM3/Finance/assignment02`, with a link left at the old location |
| Problem 2 | The same linker error as Assignment 1. **Fix:** `export SDKROOT=…/MacOSX.sdk`, then `make clean` once |
| Build | `make` works: about 12 s, no warnings |
| Unit tests | 4 of 33 pass. All 4 pass for trivial reasons (section 5) |
| Scenarios | 0 of 10 pass. `basic` sends 0 orders; 14 are expected |
| Timing | Pricing on its own: **18.88 MHz**, below 20 MHz as the assignment says. The whole-design number (62.97 MHz) is not meaningful yet (section 6) |

Neither fix changes any project file. Both problems exist only on this Mac; the graders' machines don't have them.

---

## 2. How to build (every new terminal window)

```sh
cd /Users/parva/NYU/SEM3/Finance/assignment02
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
make
make test-holes
make verify
```

The `export` lasts only for the window it's typed in. To make it permanent, run this once:

```sh
echo 'export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk' >> ~/.zshrc
```

The old location (`/Users/Shared/Files From d.localized/NYU/SEM3/Finance/assignment02`) is now a link to the new one. Opening the project from either path works.

---

## 3. Problem 1: spaces in the folder path

### The symptom

`make tools` downloaded and checked the toolchain. Then:
- **Yosys and nextpnr:** worked.
- **Verilator:** failed with:

```
Can't exec "/Users/Shared/Files": No such file or directory
%Error: verilator: Misinstalled, or VERILATOR_ROOT might need to be in environment
```

### The cause

The folder `Files From d.localized` has two spaces in its name. Finder shows it as "Files From d", because macOS hides `.localized`. Command-line tools treat a space as the end of one item, so the path splits into three pieces, none of which exists:

```
/Users/Shared/Files From d.localized/NYU/SEM3/Finance/assignment02
                   ↑    ↑
   "/Users/Shared/Files" | "From" | "d.localized/NYU/SEM3/Finance/assignment02"
```

It breaks two places:

1. **Verilator's launcher** runs its own program using its install path, without quotes.
2. **The Makefile** builds full paths from `$(CURDIR)` and `$(abspath …)` and puts them into commands without quotes. A dry run (`make -n`) showed `-I/Users/Shared/Files`, `From` and `d.localized/…` as separate arguments, in the include path, the output file, and every C++ source.

So the build couldn't work in that folder even with Verilator fixed.

### Why not edit the Makefile

Same rule as Assignment 1: the problem exists only on this Mac, so the fix belongs to this Mac, not to the course's files.

### The fix

1. **Moved** `assignment02` to `/Users/parva/NYU/SEM3/Finance/assignment02`. Same disk, so the move was a rename: instant, and git and GitHub are unaffected.
2. **Left a link** (symlink) at the old location, pointing to the new folder.

**Why the link doesn't bring the problem back:** `make` asks the operating system for the current folder, and gets the real path, not the link's path. So entering through the old path still gives `make` a path without spaces.

**How we know:**
- before moving anything, a throwaway test folder showed `make` reporting the real, space-free path when entered through a path with spaces;
- after the move, `make tools` printed all three tool versions;
- the build works.

Assignment 1 and the other courses were not moved.

---

## 4. Problem 2: the linker error (same as Assignment 1)

The first build after the move compiled everything, including Verilator's strict check of the design, then failed at the final link:

```
/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk/usr/lib/libSystem.B.tbd:4:20: error: unknown architecture
                   arm64e.x1-macos, arm64e.x1-maccatalyst ]
clang++: error: linker command failed with exit code 1
```

**Cause:** the same as in Assignment 1. A leftover macOS 27.0 SDK is newer than the installed linker. See [Assignment 1, notes/02](../../assignment01/notes/02-build-setup.md) (at `/Users/Shared/Files From d.localized/NYU/SEM3/Finance/assignment01/notes/`).

**Fix:**
1. `export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`;
2. `make clean`;
3. `make`.

Result: `build/market_maker` built in about 12 seconds, with no warnings.

---

## 5. The starting point: tests and scenarios

These numbers are the "before" picture: the starter code, with the four modules still empty.

### Unit tests (`make test-holes`): 4 of 33 pass

| Module | Tests | Pass | Fail |
|---|---|---|---|
| `market_data_parser` | 5 | 0 | 5 |
| `sequence_check` | 8 | 0 | 8 |
| `order_encoder` | 5 | 0 | 5 |
| `book` | 15 | 4 | 11 |

**Why 4 book tests already pass.** The code around `apply_update` is already written, and the empty `apply_update` returns the book unchanged. An empty book that never changes is enough for these four:

| Test | Why it passes with an empty book |
|---|---|
| `EmptyBookIsInvalid` | The book is always empty, so always invalid |
| `LatencyIsTwoCycles` | The two-cycle timing is in the existing code, not in `apply_update` |
| `ResetEmptiesTheBook` | It's always empty anyway |
| `SixteenLevelsFit` | It never overflows, because it never stores anything |

So a passing test only means something once the module does something. The other 29 tests are the real check.

### Scenarios (`make verify`): 0 of 10 pass

Every scenario fails. `./build/market_maker sim/fixtures/basic.scn` reports `orders sent: 0 (833 cycles simulated)`; `basic.expected` has 14 orders.

**Why:** the empty parser never marks any message as valid, so no market data enters the pipeline, the book stays empty, and pricing never quotes.

---

## 6. The starting point: timing

One `make timing` run on the starter code: 22 seconds, with 15 jobs in parallel. The assignment says "a few minutes"; it will take longer once the four modules are written, because there will be more logic to place.

### What the report said

**The whole design:**

| | |
|---|---|
| Max clock frequency | 62.97 MHz (15.88 ns: 8.79 logic + 7.09 routing) |
| Critical path | inside `quote_manager` |
| LUTs | 1,230 |
| Flip-flops | 1,681 |
| Block RAMs | **0** |
| Multipliers | 4 |

**Each module on its own:**

| Module | Max MHz | Min period | LUTs | Block RAMs | Multipliers |
|---|---|---|---|---|---|
| `market_data_parser` | — (empty) | — | 1 | | |
| `sequence_check` | — (empty) | — | 1 | | |
| `report_parser` | 175.07 | 5.71 ns | 889 | | |
| `merge` | 208.12 | 4.80 ns | 1,771 | | |
| `order_table` | 49.91 | 20.04 ns | 1,672 | 28 | 0 |
| `book` | 621.50 (empty) | 1.61 ns | 3 | | |
| **`pricing`** | **18.88** | **52.97 ns** | 2,714 | 0 | **28** |
| `quote_manager` | 42.76 | 23.39 ns | 2,602 | 0 | 4 |
| `order_encoder` | — (empty) | — | 1 | | |
| `register_bank` | 207.94 | 4.81 ns | 230 | | |

Source: `build/timing/<module>/pnr.log`, from commit `bc0f39c` (starter code plus notes).

### What it means

1. **Pricing is the slowest of the modules already written: 18.88 MHz on its own.**
   - This is the assignment's "under 20 MHz", and it confirms what reading the code suggested ([notes/01](01-project-overview.md), section 4).
   - Its slowest path takes 52.97 ns: 21.18 ns in logic and 31.79 ns in wiring.
   - That path passes through 78 cells, starting at one of pricing's input registers.
   - It uses 28 multiplier blocks.
   - We'll read this path step by step in Phase 4.

2. **The next slowest written modules are above 30 MHz:** `quote_manager` (42.76) and `order_table` (49.91). So speeding up pricing alone can lift the design above 30 MHz, as long as our four modules also stay above 30 MHz. The book is the one to watch.

3. **The whole-design 62.97 MHz is not meaningful yet.**
   - With the four modules empty, synthesis deletes everything whose result can never be seen.
   - The empty parser never produces market data, and the empty book never changes, so most of the pipeline's logic can't affect any output.
   - Evidence: the whole design uses **0 block RAMs**, while the order table alone uses 28. It uses **1,230 LUTs**, fewer than pricing alone (2,714).
   - The whole-design number will only mean something once all four modules are written.
   - **Lesson:** right now, the per-module numbers are the reliable ones.

4. **A quirk in the report:** the three empty modules have no register-to-register path, so nextpnr reports no frequency for them. The report script then divides by zero (`awk: division by zero`), and wrongly marks `market_data_parser` as slowest. This is harmless, and goes away once the modules are written.

This was **one run**. Measuring the run-to-run noise is Phase 4, on the finished modules.
