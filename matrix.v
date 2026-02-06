//-------------------------------------------------------------------------------------------------
module matrix
//-------------------------------------------------------------------------------------------------
(
	input  wire      clock,
	input  wire      strb,
	input  wire[7:0] code,
	input  wire[3:0] row,
	output wire[7:0] col,
	output reg       F9,
	output reg       play,
	output reg       stop
);
//-------------------------------------------------------------------------------------------------

reg[7:0] key[9:0];
initial begin
	{ F9, play, stop } = {3{ 1'b1 }};
	key[0] = 8'hFF; key[1] = 8'hFF; key[2] = 8'hFF; key[3] = 8'hFF; key[4] = 8'hFF;
	key[5] = 8'hFF; key[6] = 8'hFF; key[7] = 8'hFF; key[8] = 8'hFF; key[9] = 8'hFF;
end

//-------------------------------------------------------------------------------------------------

reg make = 1'b0;
reg extended = 1'b0;

always @(posedge clock) if(strb) begin

	case(code)
		8'hF0: make  <= 1'b1;
		8'hE0: extended <= 1'b1;
		default: { make, extended } <= 2'b00;
	endcase

	if(extended)
		case(code)
			8'h7D: play <= make; // PgUp
			8'h7A: stop <= make; // PgDown

			8'h75: key[0][4] <= make; // up
			8'h72: key[0][5] <= make; // down
			8'h6B: key[9][2] <= make; // left
			8'h74: key[9][5] <= make; // right
		endcase
	else
		case(code)
			8'h01: F9 <= make; // F9

			8'h16: key[0][0] <= make; // 1
	//		8'h00: key[0][1] <= make; // 
	//		8'h00: key[0][2] <= make; // 
			8'h58: key[0][3] <= make; // shiftlk (caps lock)
			8'h76: key[0][6] <= make; // escape
			8'h12: key[0][7] <= make; // shift (left shift)
			8'h59: key[0][7] <= make; // shift (right shift)

			8'h26: key[1][0] <= make; // 3
			8'h25: key[1][1] <= make; // 4
			8'h24: key[1][2] <= make; // E
			8'h22: key[1][3] <= make; // X
			8'h23: key[1][4] <= make; // D
			8'h21: key[1][5] <= make; // C
	//		8'h00: key[1][6] <= make; // 
	//		8'h00: key[1][7] <= make; // 

			8'h1E: key[2][0] <= make; // 2
			8'h15: key[2][1] <= make; // Q
			8'h1D: key[2][2] <= make; // W
			8'h1A: key[2][3] <= make; // Z
			8'h1B: key[2][4] <= make; // S
			8'h1C: key[2][5] <= make; // A
			8'h14: key[2][6] <= make; // control (left/right control)
	//		8'h00: key[2][7] <= make; // 

			8'h2E: key[3][0] <= make; // 5
			8'h2D: key[3][1] <= make; // R
			8'h2C: key[3][2] <= make; // T
			8'h2A: key[3][3] <= make; // V
			8'h34: key[3][4] <= make; // G
			8'h2B: key[3][5] <= make; // F
	//		8'h00: key[3][6] <= make; // 
	//		8'h00: key[3][7] <= make; // 

			8'h36: key[4][0] <= make; // 6
			8'h35: key[4][1] <= make; // Y
			8'h33: key[4][2] <= make; // H
			8'h29: key[4][3] <= make; // space
			8'h31: key[4][4] <= make; // N
			8'h32: key[4][5] <= make; // B
	//		8'h00: key[4][6] <= make; // 
	//		8'h00: key[4][7] <= make; // 

			8'h3D: key[5][0] <= make; // 7
			8'h3E: key[5][1] <= make; // 8
			8'h3C: key[5][2] <= make; // U
			8'h3A: key[5][3] <= make; // M
	//		8'h00: key[5][4] <= make; // 
			8'h3B: key[5][5] <= make; // J
	//		8'h00: key[5][6] <= make; // 
	//		8'h00: key[5][7] <= make; // 

			8'h46: key[6][0] <= make; // 9
			8'h43: key[6][1] <= make; // I
			8'h44: key[6][2] <= make; // O
			8'h41: key[6][3] <= make; // ,
	//		8'h00: key[6][4] <= make; // 
			8'h42: key[6][5] <= make; // K
	//		8'h00: key[6][6] <= make; // 
	//		8'h00: key[6][7] <= make; // 

			8'h45: key[7][0] <= make; // 0
			8'h4D: key[7][1] <= make; // P
			8'h4B: key[7][2] <= make; // L
			8'h49: key[7][3] <= make; // .
	//		8'h00: key[7][4] <= make; // 
			8'h4C: key[7][5] <= make; // ;
	//		8'h00: key[7][6] <= make; // 
	//		8'h00: key[7][7] <= make; // 

			8'h4E: key[8][0] <= make; // -
			8'h55: key[8][1] <= make; // @
			8'h54: key[8][2] <= make; // [
			8'h4A: key[8][3] <= make; // /
	//		8'h00: key[8][4] <= make; // 
			8'h52: key[8][5] <= make; // :
	//		8'h00: key[8][6] <= make; // 
	//		8'h00: key[8][7] <= make; // 

			8'h66: key[9][0] <= make; // backspace
			8'h5B: key[9][1] <= make; // ]
			8'h5A: key[9][3] <= make; // return
	//		8'h00: key[9][4] <= make; // 
	//		8'h00: key[9][6] <= make; // 
	//		8'h00: key[9][7] <= make; // 
		endcase
end

//-------------------------------------------------------------------------------------------------

assign col = key[row];

//-------------------------------------------------------------------------------------------------
endmodule
//-------------------------------------------------------------------------------------------------
