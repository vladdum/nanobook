// field_extract.sv — Top-level field extractor mux.
// Instantiates all 5 per-type extractors and muxes their outputs to a single
// book_event_t AXI-S output.

`ifndef FIELD_EXTRACT_SV
`define FIELD_EXTRACT_SV

`include "book_event_pkg.sv"
`include "extract_add.sv"
`include "extract_exec.sv"
`include "extract_cancel.sv"
`include "extract_delete.sv"
`include "extract_replace.sv"

module field_extract #(
    parameter int unsigned DATA_W = 64,
    parameter int unsigned TS_W   = 48
) (
    input  logic                       clk,
    input  logic                       rstn,

    // Five dispatch input lanes (from type_dispatch outputs).
    input  logic [DATA_W-1:0]          dispatch_add_tdata,
    input  logic [DATA_W/8-1:0]        dispatch_add_tkeep,
    input  logic                       dispatch_add_tvalid,
    output logic                       dispatch_add_tready,
    input  logic                       dispatch_add_tlast,
    input  logic [TS_W-1:0]            dispatch_add_tuser,

    input  logic [DATA_W-1:0]          dispatch_exec_tdata,
    input  logic [DATA_W/8-1:0]        dispatch_exec_tkeep,
    input  logic                       dispatch_exec_tvalid,
    output logic                       dispatch_exec_tready,
    input  logic                       dispatch_exec_tlast,
    input  logic [TS_W-1:0]            dispatch_exec_tuser,

    input  logic [DATA_W-1:0]          dispatch_cancel_tdata,
    input  logic [DATA_W/8-1:0]        dispatch_cancel_tkeep,
    input  logic                       dispatch_cancel_tvalid,
    output logic                       dispatch_cancel_tready,
    input  logic                       dispatch_cancel_tlast,
    input  logic [TS_W-1:0]            dispatch_cancel_tuser,

    input  logic [DATA_W-1:0]          dispatch_delete_tdata,
    input  logic [DATA_W/8-1:0]        dispatch_delete_tkeep,
    input  logic                       dispatch_delete_tvalid,
    output logic                       dispatch_delete_tready,
    input  logic                       dispatch_delete_tlast,
    input  logic [TS_W-1:0]            dispatch_delete_tuser,

    input  logic [DATA_W-1:0]          dispatch_replace_tdata,
    input  logic [DATA_W/8-1:0]        dispatch_replace_tkeep,
    input  logic                       dispatch_replace_tvalid,
    output logic                       dispatch_replace_tready,
    input  logic                       dispatch_replace_tlast,
    input  logic [TS_W-1:0]            dispatch_replace_tuser,

    // Single book_event_t output
    output book_event_pkg::book_event_t m_event,
    output logic                       m_valid,
    input  logic                       m_ready,

    // Stat counter passed through from extract_replace
    output logic [31:0]                replace_split
);
    import book_event_pkg::*;

    // ----------------------------------------------------------------
    // Internal signals from each extractor
    // ----------------------------------------------------------------
    book_event_t extract_add_m_event;
    logic        extract_add_m_valid;
    logic        extract_add_m_ready;

    book_event_t extract_exec_m_event;
    logic        extract_exec_m_valid;
    logic        extract_exec_m_ready;

    book_event_t extract_cancel_m_event;
    logic        extract_cancel_m_valid;
    logic        extract_cancel_m_ready;

    book_event_t extract_delete_m_event;
    logic        extract_delete_m_valid;
    logic        extract_delete_m_ready;

    book_event_t extract_replace_m_event;
    logic        extract_replace_m_valid;
    logic        extract_replace_m_ready;

    // ----------------------------------------------------------------
    // Extractor instantiations
    // ----------------------------------------------------------------
    extract_add #(
        .DATA_W(DATA_W),
        .TS_W  (TS_W)
    ) u_extract_add (
        .clk      (clk),
        .rstn     (rstn),
        .s_tdata  (dispatch_add_tdata),
        .s_tkeep  (dispatch_add_tkeep),
        .s_tvalid (dispatch_add_tvalid),
        .s_tready (dispatch_add_tready),
        .s_tlast  (dispatch_add_tlast),
        .s_tuser  (dispatch_add_tuser),
        .m_event  (extract_add_m_event),
        .m_valid  (extract_add_m_valid),
        .m_ready  (extract_add_m_ready)
    );

    extract_exec #(
        .DATA_W(DATA_W),
        .TS_W  (TS_W)
    ) u_extract_exec (
        .clk      (clk),
        .rstn     (rstn),
        .s_tdata  (dispatch_exec_tdata),
        .s_tkeep  (dispatch_exec_tkeep),
        .s_tvalid (dispatch_exec_tvalid),
        .s_tready (dispatch_exec_tready),
        .s_tlast  (dispatch_exec_tlast),
        .s_tuser  (dispatch_exec_tuser),
        .m_event  (extract_exec_m_event),
        .m_valid  (extract_exec_m_valid),
        .m_ready  (extract_exec_m_ready)
    );

    extract_cancel #(
        .DATA_W(DATA_W),
        .TS_W  (TS_W)
    ) u_extract_cancel (
        .clk      (clk),
        .rstn     (rstn),
        .s_tdata  (dispatch_cancel_tdata),
        .s_tkeep  (dispatch_cancel_tkeep),
        .s_tvalid (dispatch_cancel_tvalid),
        .s_tready (dispatch_cancel_tready),
        .s_tlast  (dispatch_cancel_tlast),
        .s_tuser  (dispatch_cancel_tuser),
        .m_event  (extract_cancel_m_event),
        .m_valid  (extract_cancel_m_valid),
        .m_ready  (extract_cancel_m_ready)
    );

    extract_delete #(
        .DATA_W(DATA_W),
        .TS_W  (TS_W)
    ) u_extract_delete (
        .clk      (clk),
        .rstn     (rstn),
        .s_tdata  (dispatch_delete_tdata),
        .s_tkeep  (dispatch_delete_tkeep),
        .s_tvalid (dispatch_delete_tvalid),
        .s_tready (dispatch_delete_tready),
        .s_tlast  (dispatch_delete_tlast),
        .s_tuser  (dispatch_delete_tuser),
        .m_event  (extract_delete_m_event),
        .m_valid  (extract_delete_m_valid),
        .m_ready  (extract_delete_m_ready)
    );

    extract_replace #(
        .DATA_W(DATA_W),
        .TS_W  (TS_W)
    ) u_extract_replace (
        .clk          (clk),
        .rstn         (rstn),
        .s_tdata      (dispatch_replace_tdata),
        .s_tkeep      (dispatch_replace_tkeep),
        .s_tvalid     (dispatch_replace_tvalid),
        .s_tready     (dispatch_replace_tready),
        .s_tlast      (dispatch_replace_tlast),
        .s_tuser      (dispatch_replace_tuser),
        .m_event      (extract_replace_m_event),
        .m_valid      (extract_replace_m_valid),
        .m_ready      (extract_replace_m_ready),
        .replace_split(replace_split)
    );

    // ----------------------------------------------------------------
    // Priority mux: only one m_valid is high at a time in correct
    // operation (dispatch lanes are mutually exclusive).
    // ----------------------------------------------------------------
    always_comb begin
        m_event                  = '0;
        m_valid                  = 1'b0;
        extract_add_m_ready     = 1'b0;
        extract_exec_m_ready    = 1'b0;
        extract_cancel_m_ready  = 1'b0;
        extract_delete_m_ready  = 1'b0;
        extract_replace_m_ready = 1'b0;
        if (extract_add_m_valid) begin
            m_event              = extract_add_m_event;
            m_valid              = 1'b1;
            extract_add_m_ready = m_ready;
        end else if (extract_exec_m_valid) begin
            m_event               = extract_exec_m_event;
            m_valid               = 1'b1;
            extract_exec_m_ready = m_ready;
        end else if (extract_cancel_m_valid) begin
            m_event                 = extract_cancel_m_event;
            m_valid                 = 1'b1;
            extract_cancel_m_ready = m_ready;
        end else if (extract_delete_m_valid) begin
            m_event                 = extract_delete_m_event;
            m_valid                 = 1'b1;
            extract_delete_m_ready = m_ready;
        end else if (extract_replace_m_valid) begin
            m_event                  = extract_replace_m_event;
            m_valid                  = 1'b1;
            extract_replace_m_ready = m_ready;
        end
    end

endmodule : field_extract

`endif // FIELD_EXTRACT_SV
