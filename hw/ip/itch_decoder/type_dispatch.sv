// type_dispatch.sv — ITCH message type dispatcher
//
// Reads the type byte (offset 0, s_tdata[7:0]) on the first beat of each
// input frame and fans the entire frame out to one of six mutually-exclusive
// AXI-S output lanes. Backpressure is fully honoured: s_tready mirrors the
// active lane's tready once the lane is locked in.
//
// Note: `default_nettype none` removed (was Vivado-incompatible: synth
// rejected `input logic *_tready` ports under that directive).
// Other modules in the pipeline don't use it; keeping consistency.

module type_dispatch #(
    parameter int unsigned DATA_W = 64,
    parameter int unsigned TS_W   = 48
) (
    input  logic                clk,
    input  logic                rstn,

    // Input AXI-S: one ITCH message per frame
    input  logic [DATA_W-1:0]   s_tdata,
    input  logic [DATA_W/8-1:0] s_tkeep,
    input  logic                s_tvalid,
    output logic                s_tready,
    input  logic                s_tlast,
    input  logic [TS_W-1:0]     s_tuser,

    // Six dispatch output lanes (mutually exclusive)
    output logic [DATA_W-1:0]   dispatch_add_tdata,
    output logic [DATA_W/8-1:0] dispatch_add_tkeep,
    output logic                dispatch_add_tvalid,
    input  logic                dispatch_add_tready,
    output logic                dispatch_add_tlast,
    output logic [TS_W-1:0]     dispatch_add_tuser,

    output logic [DATA_W-1:0]   dispatch_exec_tdata,
    output logic [DATA_W/8-1:0] dispatch_exec_tkeep,
    output logic                dispatch_exec_tvalid,
    input  logic                dispatch_exec_tready,
    output logic                dispatch_exec_tlast,
    output logic [TS_W-1:0]     dispatch_exec_tuser,

    output logic [DATA_W-1:0]   dispatch_cancel_tdata,
    output logic [DATA_W/8-1:0] dispatch_cancel_tkeep,
    output logic                dispatch_cancel_tvalid,
    input  logic                dispatch_cancel_tready,
    output logic                dispatch_cancel_tlast,
    output logic [TS_W-1:0]     dispatch_cancel_tuser,

    output logic [DATA_W-1:0]   dispatch_delete_tdata,
    output logic [DATA_W/8-1:0] dispatch_delete_tkeep,
    output logic                dispatch_delete_tvalid,
    input  logic                dispatch_delete_tready,
    output logic                dispatch_delete_tlast,
    output logic [TS_W-1:0]     dispatch_delete_tuser,

    output logic [DATA_W-1:0]   dispatch_replace_tdata,
    output logic [DATA_W/8-1:0] dispatch_replace_tkeep,
    output logic                dispatch_replace_tvalid,
    input  logic                dispatch_replace_tready,
    output logic                dispatch_replace_tlast,
    output logic [TS_W-1:0]     dispatch_replace_tuser,

    output logic [DATA_W-1:0]   dispatch_slow_tdata,
    output logic [DATA_W/8-1:0] dispatch_slow_tkeep,
    output logic                dispatch_slow_tvalid,
    input  logic                dispatch_slow_tready,
    output logic                dispatch_slow_tlast,
    output logic [TS_W-1:0]     dispatch_slow_tuser,

    output logic [31:0]         slow_path_dropped
);

  // Lane selector — latched on the first beat of each frame.
  typedef enum logic [2:0] {
    LANE_NONE    = 3'd0,
    LANE_ADD     = 3'd1,
    LANE_EXEC    = 3'd2,
    LANE_CANCEL  = 3'd3,
    LANE_DELETE  = 3'd4,
    LANE_REPLACE = 3'd5,
    LANE_SLOW    = 3'd6
  } lane_e;

  lane_e active_lane;

  // Decode the type byte into a lane selector (combinational, first-beat only).
  function automatic lane_e decode_type(input logic [7:0] t);
    case (t)
      8'h41, 8'h46:           decode_type = LANE_ADD;     // 'A', 'F'
      8'h45, 8'h43:           decode_type = LANE_EXEC;    // 'E', 'C'
      8'h58:                  decode_type = LANE_CANCEL;  // 'X'
      8'h44:                  decode_type = LANE_DELETE;  // 'D'
      8'h55:                  decode_type = LANE_REPLACE; // 'U'
      default:                decode_type = LANE_SLOW;
    endcase
  endfunction

  // Current lane: either the latched value, or (if we're at the start of a
  // new frame and input is presenting) the decoded value from byte 0.
  lane_e cur_lane;
  always_comb begin
    if (active_lane == LANE_NONE)
      cur_lane = s_tvalid ? decode_type(s_tdata[7:0]) : LANE_NONE;
    else
      cur_lane = active_lane;
  end

  // Backpressure: once a lane is known, mirror that lane's tready upstream.
  // When no lane is active and no valid input is present, open the gate so
  // the first beat can flow.
  always_comb begin
    case (cur_lane)
      LANE_ADD:     s_tready = dispatch_add_tready;
      LANE_EXEC:    s_tready = dispatch_exec_tready;
      LANE_CANCEL:  s_tready = dispatch_cancel_tready;
      LANE_DELETE:  s_tready = dispatch_delete_tready;
      LANE_REPLACE: s_tready = dispatch_replace_tready;
      LANE_SLOW:    s_tready = dispatch_slow_tready;
      default:      s_tready = 1'b1;
    endcase
  end

  // Latch the active lane on the first accepted beat; clear it on TLAST.
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      active_lane <= LANE_NONE;
    end else begin
      if (s_tvalid && s_tready) begin
        if (active_lane == LANE_NONE)
          active_lane <= decode_type(s_tdata[7:0]);
        if (s_tlast)
          active_lane <= LANE_NONE;
      end
    end
  end

  // slow_path_dropped: increment once per slow message (on first beat accepted).
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      slow_path_dropped <= '0;
    end else begin
      if (s_tvalid && s_tready && active_lane == LANE_NONE &&
          decode_type(s_tdata[7:0]) == LANE_SLOW)
        slow_path_dropped <= slow_path_dropped + 32'd1;
    end
  end

  // Output fan-out: forward input to the active lane, gate tvalid.
  // All lanes share the same data/keep/last/user — only tvalid differs.

  assign dispatch_add_tdata   = s_tdata;
  assign dispatch_add_tkeep   = s_tkeep;
  assign dispatch_add_tlast   = s_tlast;
  assign dispatch_add_tuser   = s_tuser;
  assign dispatch_add_tvalid  = s_tvalid && (cur_lane == LANE_ADD);

  assign dispatch_exec_tdata  = s_tdata;
  assign dispatch_exec_tkeep  = s_tkeep;
  assign dispatch_exec_tlast  = s_tlast;
  assign dispatch_exec_tuser  = s_tuser;
  assign dispatch_exec_tvalid = s_tvalid && (cur_lane == LANE_EXEC);

  assign dispatch_cancel_tdata  = s_tdata;
  assign dispatch_cancel_tkeep  = s_tkeep;
  assign dispatch_cancel_tlast  = s_tlast;
  assign dispatch_cancel_tuser  = s_tuser;
  assign dispatch_cancel_tvalid = s_tvalid && (cur_lane == LANE_CANCEL);

  assign dispatch_delete_tdata  = s_tdata;
  assign dispatch_delete_tkeep  = s_tkeep;
  assign dispatch_delete_tlast  = s_tlast;
  assign dispatch_delete_tuser  = s_tuser;
  assign dispatch_delete_tvalid = s_tvalid && (cur_lane == LANE_DELETE);

  assign dispatch_replace_tdata  = s_tdata;
  assign dispatch_replace_tkeep  = s_tkeep;
  assign dispatch_replace_tlast  = s_tlast;
  assign dispatch_replace_tuser  = s_tuser;
  assign dispatch_replace_tvalid = s_tvalid && (cur_lane == LANE_REPLACE);

  assign dispatch_slow_tdata  = s_tdata;
  assign dispatch_slow_tkeep  = s_tkeep;
  assign dispatch_slow_tlast  = s_tlast;
  assign dispatch_slow_tuser  = s_tuser;
  assign dispatch_slow_tvalid = s_tvalid && (cur_lane == LANE_SLOW);

endmodule : type_dispatch

`default_nettype wire
