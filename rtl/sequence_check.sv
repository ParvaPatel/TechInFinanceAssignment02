// This file was generated with the help of Claude Code.
//
// Sequence check: the first pipeline stage. Wraps each decoded market data
// event in a pipeline_item_t and sets errors.sequence_gap if a feed message
// was missed.
//
// The feed numbers its messages 1, 2, 3, ... A message whose number isn't the
// expected one means at least one message was missed (or arrived twice). A gap
// is a standing error: errors.sequence_gap is set on the message that reveals
// it and on every message after it, until reset. After each message, the
// expected number becomes that message's number plus one.
//
// The event itself always passes through unchanged: this stage only flags the
// gap, and the quote manager decides what to do about it.
//
// Timing: a registered stage, so item_valid is high exactly one cycle after
// market_event_valid. A new event may arrive every cycle.
module sequence_check
    import messages_pkg::*;
    import pipeline_pkg::*;
(
    input  logic               clk,
    input  logic               rst,

    /* verilator lint_off UNUSEDSIGNAL */
    input  logic               market_event_valid,
    input  market_data_event_t market_event,
    /* verilator lint_on UNUSEDSIGNAL */

    output logic               item_valid,
    output pipeline_item_t     item
);

    // Registers: item_valid/item are the outputs. You'll also need your own
    // internal registers to track the sequence state between messages (see
    // the discussion above) -- declare them, and their _next counterparts,
    // next to these.
    logic           item_valid_next;
    pipeline_item_t item_next;

    always_comb begin
        // TODO: each cycle,
        //  1. Compare this message's sequence number against the number you
        //     expect next, to tell whether a gap opens on this message.
        //  2. Combine that with whether a gap was already seen on an earlier
        //     message: the gap is sticky.
        //  3. Update your internal registers' _next values for next cycle
        //     (hold them unchanged when market_event_valid is low).
        //  4. Set item_valid_next: high exactly when market_event_valid is
        //     high (this stage registers every event, valid or not).
        //  5. Build item_next: source = SOURCE_MARKET_DATA, market_event =
        //     market_event, and errors.sequence_gap set from step 2.
        item_valid_next = 1'b0;
        item_next       = '0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            item_valid <= 1'b0;
        end else begin
            item_valid <= item_valid_next;
        end
        // No reset: the item only matters when item_valid is high. Register
        // your own internal state here too, following the same style (an
        // always_ff per stage, synchronous reset only on control registers).
        item <= item_next;
    end

endmodule
