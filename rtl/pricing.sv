// This file was generated with the help of Claude Code.
//
// Pricing: turns the top of book into the quotes we want, without dividing.
//
// Fair value is the microprice of the best bid B and offer A:
//
//     fair value = (B * ask size + A * bid size) / (bid size + ask size)
//
// A divider is far too large and slow for the hot path, but we never need
// fair value itself, only the ticks just below and above it (our quotes are on
// the tick grid). Two facts make those cheap:
//
//   - Fair value lies between B and A. With some algebra,
//         fair value - B = (A - B) * bid size / (bid size + ask size)
//     so if the spread is S ticks, the tick just below fair value is B + k
//     ticks, where k is the largest whole number with
//         k * (bid size + ask size) <= S * bid size.
//     k is between 0 and S - 1, so every candidate is checked at once (one
//     comparison per possible k) and the largest that holds is taken.
//   - The credit is a whole number of ticks (the CPU rounds it up), so
//         bid = (tick at or below fair value) - credit
//         ask = (tick at or above fair value) + credit
//     with no further rounding.
//
// The comparisons bound the spread: markets wider than MAX_SPREAD_TICKS
// aren't quoted. can_quote is false then, when the book is invalid, or when
// the bid would not be positive; the prices are zero whenever it is false.
//
// Timing: two registered stages, with no state between items. The chain is
// split by a register after the multiply (S * bid size), so neither half is
// as slow as the whole. item_valid is high exactly two cycles after
// in_item_valid.

module pricing
    import config_pkg::*;
    import messages_pkg::*;
    import pipeline_pkg::*;
(
    input  logic          clk,
    input  logic          rst,

    input  logic          in_item_valid,
    input  pricing_item_t in_item,

    // From the register bank: the half-spread, a whole number of ticks.
    input  logic [31:0]   credit,

    output logic          item_valid,
    output quote_item_t   item
);

     // Stage 1 -> stage 2 registers: stage 1's results, and the parts of the
    // item stage 2 still needs.
    logic          stage_valid, stage_valid_next;
    logic [31:0]   stage_bid_price, stage_bid_price_next;        // B
    logic [31:0]   stage_spread, stage_spread_next;              // A - B, in price units
    int            stage_spread_ticks, stage_spread_ticks_next;  // S
    logic [36:0]   stage_multiples      [1:MAX_SPREAD_TICKS-1];  // k * (bid size + ask size), k = 1..15
    logic [36:0]   stage_multiples_next [1:MAX_SPREAD_TICKS-1];
    logic [36:0]   stage_weighted, stage_weighted_next;          // S * bid size
    item_source_e  stage_source, stage_source_next;
    report_event_t stage_report_event, stage_report_event_next;
    error_flags_t  stage_errors, stage_errors_next;

    logic        item_valid_next;
    quote_item_t item_next;

    // Stage 1: the spread, the spread in ticks, and S * bid size.
    always_comb begin
        top_of_book_t top;
        logic [31:0]  spread;
        int           spread_ticks;

        top    = in_item.top_of_book;
        spread = top.ask_price - top.bid_price;

        // The spread in ticks, by comparison with each multiple of the tick.
        spread_ticks = 0;
        for (int j = 1; j <= MAX_SPREAD_TICKS; ++j) begin
            if (spread >= j * TICK_SIZE) spread_ticks = j;
        end

        stage_valid_next        = in_item_valid;
        stage_bid_price_next    = top.bid_price;
        stage_spread_next       = spread;
        stage_spread_ticks_next = spread_ticks;
        // k * total size for every candidate k. These need only the sizes, so
        // they run alongside the spread in ticks, not after it.
        for (int j = 1; j < MAX_SPREAD_TICKS; ++j) begin
            stage_multiples_next[j] = 37'(j) * (37'(top.bid_size) + 37'(top.ask_size));
        end
        stage_weighted_next     = 37'(spread_ticks) * {5'd0, top.bid_size};
        stage_source_next       = in_item.source;
        stage_report_event_next = in_item.report_event;
        stage_errors_next       = in_item.errors;
    end

    // Stage 2: the largest k, the ticks either side of fair value, the credit.
    always_comb begin
        int           below;          // k: fair value's tick, counted from B
        logic         on_tick;        // fair value is exactly on a tick
        logic [31:0]  tick_below;     // the tick at or below fair value
        logic [31:0]  tick_above;     // the tick at or above fair value
        logic         can_quote;

        // The largest k with k * total size <= S * bid size (k < S), and
        // whether that is an exact equality.
        below   = 0;
        on_tick = stage_weighted == '0;
        for (int j = 1; j < MAX_SPREAD_TICKS; ++j) begin
            if (j < stage_spread_ticks && stage_multiples[j] <= stage_weighted) begin
                below   = j;
                on_tick = stage_multiples[j] == stage_weighted;
            end
        end

        tick_below = stage_bid_price + 32'(below) * TICK_SIZE;
        tick_above = on_tick ? tick_below : tick_below + TICK_SIZE;

        can_quote = !stage_errors.book_invalid
                 && stage_spread_ticks >= 1
                 && stage_spread <= MAX_SPREAD_TICKS * TICK_SIZE
                 && tick_below > credit;

        item_valid_next        = stage_valid;
        item_next              = '0;
        item_next.can_quote    = can_quote;
        item_next.bid_price    = can_quote ? tick_below - credit : '0;
        item_next.ask_price    = can_quote ? tick_above + credit : '0;
        item_next.source       = stage_source;
        item_next.report_event = stage_report_event;
        item_next.errors       = stage_errors;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            stage_valid <= 1'b0;
            item_valid  <= 1'b0;
        end else begin
            stage_valid <= stage_valid_next;
            item_valid  <= item_valid_next;
        end
        // No reset: these only matter when stage_valid / item_valid is high.
        stage_bid_price    <= stage_bid_price_next;
        stage_spread       <= stage_spread_next;
        stage_spread_ticks <= stage_spread_ticks_next;
        stage_multiples    <= stage_multiples_next;
        stage_weighted     <= stage_weighted_next;
        stage_source       <= stage_source_next;
        stage_report_event <= stage_report_event_next;
        stage_errors       <= stage_errors_next;
        item               <= item_next;
    end

endmodule
