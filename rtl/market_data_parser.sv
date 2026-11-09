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

    wire [7:0] message_type = in_data[7:0];

    logic               market_event_valid_next;
    market_data_event_t market_event_next;

    // A field n bytes long at byte offset o is in_data[8*o +: 8*n]
    // (design doc, Appendix B). Every message starts with a 19-byte header:
    // type 0, instrument 1, sequence 3, timestamp 11; the order ref follows
    // at 19. Fields a type doesn't carry stay zero.

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
        market_event_valid_next = in_valid;
        market_event_next       = '0;
        market_event_next.sequence_number = in_data[8*3 +: 64];   // sequence, bytes 3-10
        market_event_next.order_ref       = in_data[8*19 +: 64];  // order ref, bytes 19-26

        case (message_type)
            TYPE_ADD: begin
                market_event_next.kind   = MARKET_DATA_ADD;
                market_event_next.is_buy = in_data[8*27 +: 8] == SIDE_BUY;  // side, byte 27
                market_event_next.shares = in_data[8*28 +: 32];             // shares, bytes 28-31
                market_event_next.price  = in_data[8*32 +: 64];             // price, bytes 32-39
            end
            TYPE_EXECUTED: begin
                market_event_next.kind   = MARKET_DATA_EXECUTED;
                market_event_next.shares = in_data[8*27 +: 32];  // executed shares, bytes 27-30
            end
            TYPE_CANCEL: begin
                market_event_next.kind   = MARKET_DATA_CANCEL;
                market_event_next.shares = in_data[8*27 +: 32];  // canceled shares, bytes 27-30
            end
            TYPE_DELETE: begin
                market_event_next.kind = MARKET_DATA_DELETE;
            end
            TYPE_REPLACE: begin
                market_event_next.kind          = MARKET_DATA_REPLACE;
                market_event_next.new_order_ref = in_data[8*27 +: 64];  // new order ref, bytes 27-34
                market_event_next.shares        = in_data[8*35 +: 32];  // shares, bytes 35-38
                market_event_next.price         = in_data[8*39 +: 64];  // price, bytes 39-46
            end
            default: begin
                market_event_valid_next = 1'b0;  // unknown type: ignored
            end
        endcase
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
