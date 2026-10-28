// This file was generated with the help of Claude Code.
//
// Order encoder: turns one order_request_t per valid cycle into a whole order
// entry message (EnterOrder, ReplaceOrder, or CancelOrder).
//
// Timing: the message is registered, so order_valid is high exactly one cycle
// after request_valid. A new request may arrive every cycle. The message's
// length is implied by its type byte; bytes past the end are zero.
module order_encoder
    import messages_pkg::*;
(
    input  logic                    clk,
    input  logic                    rst,

    /* verilator lint_off UNUSEDSIGNAL */
    input  logic                    request_valid,
    input  order_request_t          request,
    /* verilator lint_on UNUSEDSIGNAL */

    output logic                    order_valid,
    output logic [MESSAGE_BITS-1:0] order_data
);

    logic                    order_valid_next;
    logic [MESSAGE_BITS-1:0] order_data_next;

    always_comb begin
        // TODO: encode request into order_data_next, based on request.kind
        // (ORDER_ENTER / ORDER_REPLACE / ORDER_CANCEL). See the design doc's
        // order API appendix for each type's byte layout, and
        // messages_pkg.sv for the field offsets (ORDER_*_OFFSET constants),
        // TYPE_* type bytes, and the instrument/time-in-force constants.
        //
        //  - Fields a given message type doesn't set should stay zero
        //    (bytes past the message's end are zero).
        //  - order_valid_next should be high exactly when request_valid is
        //    high and request.kind is one of the three known kinds (the
        //    message is registered, so order_valid becomes high one cycle
        //    later).
        order_valid_next = 1'b0;
        order_data_next  = '0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            order_valid <= 1'b0;
        end else begin
            order_valid <= order_valid_next;
        end
        // No reset: the message only matters when order_valid is high.
        order_data <= order_data_next;
    end

endmodule
