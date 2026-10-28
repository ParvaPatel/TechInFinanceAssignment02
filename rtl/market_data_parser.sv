// This file was generated with the help of Claude Code.
//
// Market data parser: decodes one whole market data message per valid cycle
// into a market_data_event_t.
//
// Timing: the event is registered, so market_event_valid is high exactly one
// cycle after in_valid. A new message may arrive every cycle. Messages of an
// unknown type are ignored (market_event_valid stays low).
module market_data_parser
    import messages_pkg::*;
(
    input  logic                    clk,
    input  logic                    rst,

    // One whole message per valid cycle. Byte 0 (the type) is in bits [7:0];
    // bytes past the end of the message are zero. The instrument (there is
    // only one), the timestamp, and the padding are deliberately not decoded.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic                    in_valid,
    input  logic [MESSAGE_BITS-1:0] in_data,
    /* verilator lint_on UNUSEDSIGNAL */

    output logic                    market_event_valid,
    output market_data_event_t      market_event
);

    logic               market_event_valid_next;
    market_data_event_t market_event_next;

    always_comb begin
        // TODO: decode in_data into market_event_next, based on its message
        // type (byte 0, in_data[7:0]). See the design doc's wire-format
        // appendix for each type's byte layout, and messages_pkg.sv for the
        // field offsets (*_OFFSET constants) and the TYPE_* type bytes.
        //
        //  - sequence_number and order_ref sit at the same offset in every
        //    message type.
        //  - Each type has its own fields beyond that (new order ref, side,
        //    shares, price) -- not every type uses every field.
        //  - A message of an unknown type carries no event: leave
        //    market_event_valid_next low.
        //  - market_event_valid_next should be high exactly when in_valid is
        //    high and the type is known (the event is registered, so
        //    market_event_valid becomes high one cycle later).
        market_event_valid_next = 1'b0;
        market_event_next       = '0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            market_event_valid <= 1'b0;
        end else begin
            market_event_valid <= market_event_valid_next;
        end
        // No reset: the event only matters when market_event_valid is high.
        market_event <= market_event_next;
    end

endmodule
