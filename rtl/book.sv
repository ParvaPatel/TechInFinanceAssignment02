// This file was generated with the help of Claude Code.
//
// Book: applies the order table's level updates to the top LEVELS price
// levels of each side, and produces the top of book (the best bid and offer,
// excluding our own orders) for pricing.
//
// Each side is a sorted list in registers, best price first: bids highest
// first, asks lowest first. An update compares its price against every level
// at once (in parallel), then either changes that level's size, removes the
// level (shifting the worse levels up), or inserts a new level (shifting the
// worse levels down). Reading the top of book is free: it is level 0 of each
// side.
//
// An item may carry two updates (a replace). Applying both in one cycle
// would chain a second compare-and-shift onto the first, which is several
// times larger and slower, so each item takes two cycles: update 0 in the
// first, update 1 (if any) in the second. Both cycles use the same update
// logic. This relies on items arriving at least two cycles apart, which the
// merge guarantees.
//
// Only the top LEVELS levels are kept. If a side would need more (a new level
// that is worse than all of them, or one that pushes the worst out), the book
// can no longer be trusted: once those better levels empty, the dropped level
// should have become visible. So errors.book_overflow is set, on that item
// and every item after it, and the quote manager stops quoting. (Real systems
// back a cache like this with a full-depth store and refill it instead.)
//
// errors.book_invalid is set on any item after which a side is empty or the
// book is crossed (best bid at or above best offer).
//
// Timing: two cycles. item_valid is high exactly two cycles after
// in_item_valid, and the item carries the top of book after its updates.
module book
    import messages_pkg::*;
    import pipeline_pkg::*;
#(
    parameter int LEVELS = 16  // per side
) (
    input  logic          clk,
    input  logic          rst,

    // At most one item every two cycles.
    input  logic          in_item_valid,
    input  book_item_t    in_item,

    output logic          item_valid,
    output pricing_item_t item
);

    typedef struct packed {
        logic        valid;
        logic [31:0] price;
        logic [31:0] size;   // total shares resting at this price
    } level_t;

    // One side of the book: level 0 is the best price.
    typedef level_t [LEVELS-1:0] side_t;

    // The result of applying one update to a side.
    typedef struct packed {
        side_t levels;
        logic  overflow;  // a level could not be stored, or was pushed out
    } update_result_t;

    // Is price `a` better than price `b` on this side?
    function automatic logic better(logic is_buy, logic [31:0] a, logic [31:0] b);
        return is_buy ? a > b : a < b;
    endfunction

    // Applies one level update to one side of the book. Positions in the list
    // are bit masks (one bit per level), so each level's new value depends on
    // a couple of bits and its neighbors.
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic update_result_t apply_update(side_t levels, level_update_t update);
    /* verilator lint_on UNUSEDSIGNAL */
        // TODO: apply one level update to one sorted side of the book.
        //
        //  - update.valid false: nothing to do; return levels unchanged.
        //  - An existing level at update.price: a size change (update.add:
        //    grow it by update.shares; otherwise shrink it). If shrinking
        //    empties it (shares removed >= its current size), remove it
        //    instead -- every worse level shifts up one place, and the last
        //    place becomes invalid.
        //  - No level at update.price, and update.add: insert a new level in
        //    sorted order (use `better` to compare prices) -- every worse
        //    level shifts down one place. If the side was already full (its
        //    worst level was valid), that level falls off the bottom and
        //    result.overflow is set.
        //  - No level at update.price, and !update.add: shares are leaving a
        //    level the book isn't tracking -- should only happen after an
        //    overflow. Set result.overflow.
        //
        // Consider all LEVELS levels together, in parallel, not one at a
        // time: for each level, what determines its *new* value from the
        // *old* values of its neighbors?
        update_result_t    result;
        logic [LEVELS-1:0] is_better;   // level i is valid and better than the update's price
        logic [LEVELS-1:0] is_match;    // level i is valid and at the update's price
        logic [LEVELS-1:0] is_emptied;  // level i is the match, and the update removes all of it
        logic [LEVELS-1:0] is_new;      // level i is where a new level goes
        logic              found;       // the update's price is in the book
        logic              emptied;     // the update removes its whole level
        side_t             moved_up;    // moved_up[i]   = levels[i+1]; the last place empty
        side_t             moved_down;  // moved_down[i] = levels[i-1]; the first place empty
        level_t            new_level;

        // Every level compares itself with the update at once. The list is
        // sorted, so is_better is a run of ones followed by zeros: the levels
        // that stay put.
        for (int i = 0; i < LEVELS; ++i) begin
            is_better[i]  = levels[i].valid && better(update.is_buy, levels[i].price, update.price);
            is_match[i]   = levels[i].valid && levels[i].price == update.price;
            is_emptied[i] = is_match[i] && update.shares >= levels[i].size;
        end
        found   = |is_match;
        emptied = !update.add && |is_emptied;

        // A new level goes at the first level that isn't better than it: the
        // place whose upper neighbor is better, or the top.
        is_new = ~is_better & {is_better[LEVELS-2:0], 1'b1};

        // Each level's neighbors, as whole shifted copies of the side.
        moved_up   = levels >> $bits(level_t);
        moved_down = levels << $bits(level_t);

        new_level.valid = 1'b1;
        new_level.price = update.price;
        new_level.size  = update.shares;

        result.levels   = levels;
        result.overflow = 1'b0;
        if (!update.valid) begin
            // Nothing to do.
        end else if (found && !emptied) begin
            // A size change at an existing level; nothing moves.
            for (int i = 0; i < LEVELS; ++i) begin
                if (is_match[i]) begin
                    result.levels[i].size = update.add ? levels[i].size + update.shares
                                                       : levels[i].size - update.shares;
                end
            end
        end else if (found) begin
            // The level empties: it and every worse level take the next one's
            // value, and the last place becomes empty.
            for (int i = 0; i < LEVELS; ++i) begin
                if (!is_better[i]) result.levels[i] = moved_up[i];
            end
        end else if (update.add) begin
            // Insert: the new level at its place, every worse level moves down.
            // A full side loses its worst level, or can't store a worse one.
            for (int i = 0; i < LEVELS; ++i) begin
                if (is_new[i]) begin
                    result.levels[i] = new_level;
                end else if (!is_better[i]) begin
                    result.levels[i] = moved_down[i];
                end
            end
            result.overflow = levels[LEVELS-1].valid;
        end else begin
            // Shares leaving a level we don't track: only after an overflow.
            result.overflow = 1'b1;
        end
        return result;

    endfunction

    // ---------------------------------------------------------------------
    // Registers: both sides of the book, the sticky overflow, the item
    // between its two cycles, and the output.
    // ---------------------------------------------------------------------
    side_t         bids, bids_next;
    side_t         asks, asks_next;
    logic          overflow_seen, overflow_seen_next;
    logic          second_cycle, second_cycle_next;  // pending_item is in its second cycle
    book_item_t    pending_item, pending_item_next;
    logic          item_valid_next;
    pricing_item_t item_next;

    always_comb begin
        level_update_t  update;        // the update due this cycle
        update_result_t result;
        side_t          bids_updated;  // the book after this cycle's update
        side_t          asks_updated;
        logic           overflow;      // seen at or before this cycle

        // First cycle of an item: its update 0. Second cycle: its update 1.
        update = second_cycle ? pending_item.level_updates[1] : in_item.level_updates[0];
        if (!second_cycle && !in_item_valid) begin
            update = '0;
        end

        bids_updated = bids;
        asks_updated = asks;
        if (update.is_buy) begin
            result       = apply_update(bids, update);
            bids_updated = result.levels;
        end else begin
            result       = apply_update(asks, update);
            asks_updated = result.levels;
        end
        overflow = overflow_seen || result.overflow;

        bids_next          = bids_updated;
        asks_next          = asks_updated;
        overflow_seen_next = overflow;

        // The item waits here during its second cycle.
        second_cycle_next = !second_cycle && in_item_valid;
        pending_item_next = in_item;

        // After the second cycle, the item leaves with the resulting top of book.
        item_valid_next                 = second_cycle;
        item_next                       = '0;
        item_next.top_of_book.bid_price = bids_updated[0].price;
        item_next.top_of_book.bid_size  = bids_updated[0].size;
        item_next.top_of_book.ask_price = asks_updated[0].price;
        item_next.top_of_book.ask_size  = asks_updated[0].size;
        item_next.source                = pending_item.source;
        item_next.report_event          = pending_item.report_event;
        item_next.errors                = pending_item.errors;
        item_next.errors.book_overflow  = overflow;
        item_next.errors.book_invalid   = !bids_updated[0].valid || !asks_updated[0].valid
                                       || bids_updated[0].price >= asks_updated[0].price;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            bids          <= '0;
            asks          <= '0;
            overflow_seen <= 1'b0;
            second_cycle  <= 1'b0;
            item_valid    <= 1'b0;
        end else begin
            bids          <= bids_next;
            asks          <= asks_next;
            overflow_seen <= overflow_seen_next;
            second_cycle  <= second_cycle_next;
            item_valid    <= item_valid_next;
        end
        // No reset: these only matter when second_cycle / item_valid is high.
        pending_item <= pending_item_next;
        item         <= item_next;
    end

endmodule
