//-------------------------------------------------------------------------------------------------
module dprf
//-------------------------------------------------------------------------------------------------
#
(
	parameter KB = 0,
	parameter DW = 8,
	parameter FN = ""
)
(
	input  wire                      clock1,
	input  wire[$clog2(KB*1024)-1:0] a1,
	input  wire[             DW-1:0] d1,
	output reg [             DW-1:0] q1,
	input  wire                      w1,
	input  wire                      clock2,
	input  wire[$clog2(KB*1024)-1:0] a2,
	input  wire[             DW-1:0] d2,
	output reg [             DW-1:0] q2,
	input  wire                      w2
);
//-------------------------------------------------------------------------------------------------

reg[DW-1:0] mem[0:(KB*1024)-1];
initial if(FN != "") $readmemh(FN, mem, 0);

always @(posedge clock1) begin q1 <= mem[a1]; if(w1) mem[a1] <= d1; end
always @(posedge clock2) begin q2 <= mem[a2]; if(w2) mem[a2] <= d2; end

//-------------------------------------------------------------------------------------------------
endmodule
//-------------------------------------------------------------------------------------------------

//-------------------------------------------------------------------------------------------------
module dprs
//-------------------------------------------------------------------------------------------------
#
(
	parameter KB = 0,
	parameter DW = 8,
	parameter FN = ""
)
(
	input  wire                      clock1,
	input  wire[$clog2(KB*1024)-1:0] a1,
	output reg [             DW-1:0] q1,
	input  wire                      clock2,
	input  wire[$clog2(KB*1024)-1:0] a2,
	input  wire[             DW-1:0] d2,
	output reg [             DW-1:0] q2,
	input  wire                      w2
);
//-------------------------------------------------------------------------------------------------

reg[DW-1:0] mem[0:(KB*1024)-1];
initial if(FN != "") $readmemh(FN, mem, 0);

wire w1 = 1'b0;
wire[7:0] d1 = 8'hFF;

always @(posedge clock1) begin q1 <= mem[a1]; if(w1) mem[a1] <= d1; end
always @(posedge clock2) begin q2 <= mem[a2]; if(w2) mem[a2] <= d2; end

//-------------------------------------------------------------------------------------------------
endmodule
//-------------------------------------------------------------------------------------------------
