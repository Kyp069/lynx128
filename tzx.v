//-------------------------------------------------------------------------------------------------
// tzx_sd - reproductor de cintas TZX/CDT leídas directamente de la SD, por sectores
// Shaeon (Carlos Palmero) y Kyp (Kyp069). Libre para cualquier core.
//
// Para cualquier ordenador que use cintas TZX (o CDT, que es el mismo formato): Spectrum, Amstrad
// CPC, Enterprise, Lynx, MSX... El fichero se monta como una imagen de disco (en MiST/SiDi/Calypso
// "S<n>U,TZXCDT,Mount tape;", en MiSTer igual con hps_io) y no se carga en memoria: el módulo pide
// al firmware los sectores de 512 bytes que necesita y los guarda en una caché de 2 sectores
// (1 KB de BRAM). Mientras se reproduce un sector, pide por adelantado el siguiente.
//
// El módulo recorre él mismo los bloques de la cinta y resuelve:
//   - saltos (0x23), bucles (0x24/0x25), llamadas a secuencias (0x26/0x27) y selección (0x28)
//   - bloques CSW con compresión RLE (0x18), que convierte en pulsos
//   - bloques informativos, de grupo y desconocidos (se saltan)
// y a tzxplayer.vhd (György Szombathelyi) solo le pasa los bloques con señal: 0x10-0x15, 0x19,
// 0x20, 0x2A y 0x2B. Las duraciones de los bloques TZX están en T-estados de 3,5 MHz para todas las
// máquinas; tzxplayer los convierte al reloj del core con TZX_MS (pulsos de ce por milisegundo).
//
// Mandos (pulsos de un ciclo, o niveles: se detecta el flanco de subida):
//   play    arranca o sigue desde donde se paró (si la cinta había llegado al final, desde el
//           principio). En un bloque de selección, elige la primera opción.
//   stop    pausa (al pulsar play sigue desde ahí)
//   rewind  para y vuelve al principio
//   motor   control remoto del motor del ordenador (CPC, MSX, Enterprise...): con motor = 0 la
//           cinta no avanza aunque esté en play. Los cores sin control de motor lo ponen a 1.
//   stop48  1: el bloque 0x2A ("parar si es un 48K") para la cinta; solo tiene sentido en Spectrum.
//   select  en un bloque de selección (selecting = 1, la cinta parada), salta a la opción
//           sel_index (0 .. sel_count-1) y sigue.
// Los bloques 0x20 con pausa 0 ("parar la cinta") la paran; al pulsar play sigue.
//
// Conexión con el firmware:
//   - MiST/SiDi/Calypso (user_io): sd_ack debe ser el ack de ESTA imagen (sd_ack_x[n]), y la
//     multiplexación de sd_lba / sd_rd con las demás imágenes la hace el core.
//   - MiSTer (hps_io): sd_lba[n], sd_rd[n], sd_ack[n] de esta unidad, con BLKSZ de 512 bytes.
//   El último sector de casi todos los TZX está incompleto: hace falta un firmware que lo lea
//   (mist-firmware desde el commit 002146a, calypso-firmware desde la versión que lo incluye).
//-------------------------------------------------------------------------------------------------
module tzx
#(
	parameter TZX_MS = 56000,             // pulsos de ce por milisegundo (reloj en kHz si ce = 1).
	                                      // Si pasa de 65535, el módulo divide ce internamente

	// duraciones del bloque estándar 0x10 (en T-estados de 3,5 MHz). Por defecto, las de la ROM
	// del Spectrum. Para Amstrad CPC: 2000, 855, 855, 855, 1710, 4095, 4095.
	parameter NORMAL_PILOT_LEN    = 2168,
	parameter NORMAL_SYNC1_LEN    = 667,
	parameter NORMAL_SYNC2_LEN    = 735,
	parameter NORMAL_ZERO_LEN     = 855,
	parameter NORMAL_ONE_LEN      = 1710,
	parameter HEADER_PILOT_PULSES = 8063,
	parameter NORMAL_PILOT_PULSES = 3223,

	// bloques cuya posición se recuerda para los saltos (2 o más). Más allá, un salto recorre la
	// cinta desde el último bloque recordado. 256 ocupan 1 bloque de memoria (8 Kbit).
	parameter MAXBLK = 256,

	// 1: reproduce los bloques CSW (0x18). 0: se saltan, y el módulo ocupa algo menos
	parameter CSW = 1
)
(
	input  wire       clock,
	input  wire       ce,                 // habilitación de reloj de tzxplayer (1 si no hace falta)

	// imagen montada (user_io / hps_io)
	input  wire       img_mounted,        // pulso al montar una imagen en esta unidad
	input  wire[31:0] img_size,           // válido en el ciclo de img_mounted
	output reg [31:0] sd_lba = 32'd0,
	output reg        sd_rd = 1'b0,
	input  wire       sd_ack,             // ack de esta imagen
	input  wire[ 8:0] sd_buff_addr,
	input  wire[ 7:0] sd_buff_dout,
	input  wire       sd_buff_wr,

	// mandos
	input  wire       play,
	input  wire       stop,
	input  wire       rewind,
	input  wire       motor,
	input  wire       stop48,
	input  wire       select,
	input  wire[ 7:0] sel_index,

	// estado
	output wire       tape,               // señal de la cinta (nivel EAR / datos de casete)
	output wire       busy,               // la cinta está girando
	output reg        playing = 1'b0,     // play pulsado (aunque el motor del ordenador esté parado)
	output reg        valid = 1'b0,       // hay montado un TZX/CDT válido
	output reg        selecting = 1'b0,   // parada en un bloque de selección
	output reg [ 7:0] sel_count = 8'd0,   // opciones del bloque de selección
	output wire[31:0] pos,                // byte del fichero por el que va (para una barra de progreso)
	output wire[31:0] size,
	output wire       loading             // leyendo un sector de la SD (para un LED)
);
//--- flancos de los mandos -----------------------------------------------------------------------

	reg playP = 1'b0, stopP = 1'b0, rewP = 1'b0, selP = 1'b0;
	always @(posedge clock) begin playP <= play; stopP <= stop; rewP <= rewind; selP <= select; end
	wire playE = play && !playP;
	wire stopE = stop && !stopP;
	wire rewE  = rewind && !rewP;
	wire selE  = select && !selP;

//--- caché de 2 sectores -------------------------------------------------------------------------

	reg [7:0] cache[0:1023];              // slot 0: 0-511, slot 1: 512-1023
	reg [9:0] cRa;
	reg [7:0] cQ;
	reg       wSlot;                      // slot que se está llenando
	always @(posedge clock) begin
		if(sd_ack && sd_buff_wr) cache[{ wSlot, sd_buff_addr }] <= sd_buff_dout;
		cQ <= cache[cRa];
	end

	reg [14:0] tag[0:1];                  // sector guardado en cada slot (ficheros de hasta 16 MB)
	reg  [1:0] valid_s = 2'b00;
	reg [23:0] fsize = 24'd0;
	reg        mounted = 1'b0;
	reg        ld = 1'b0;                 // lectura de un sector en curso
	reg        ackP = 1'b0;
	reg        sigOk = 1'b0;

	assign loading = ld;
	assign size = { 8'd0, fsize };

	wire[14:0] lastSec = fsize[23:9] - { 14'd0, fsize[8:0] == 9'd0 };

	function [7:0] tzxSig(input [2:0] i);   // "ZXTape!" + 0x1A (TZX y CDT)
		case(i)
			0: tzxSig = "Z"; 1: tzxSig = "X"; 2: tzxSig = "T"; 3: tzxSig = "a";
			4: tzxSig = "p"; 5: tzxSig = "e"; 6: tzxSig = "!"; default: tzxSig = 8'h1A;
		endcase
	endfunction

//--- servidor de bytes ---------------------------------------------------------------------------

	// petición de un byte: rReq != rAck; dirección rA; dato en rQ
	reg        rReq = 1'b0, rAck = 1'b0;
	reg [23:0] rA;
	reg  [7:0] rQ;
	reg  [1:0] rLat = 2'd0;
	reg        rBusy = 1'b0;
	reg [14:0] curSec = 15'd0;            // último sector servido (para la lectura adelantada)

	wire[14:0] reqSec = rA[23:9];
	wire       hit0 = valid_s[0] && tag[0] == reqSec;
	wire       hit1 = valid_s[1] && tag[1] == reqSec;
	wire       nxtCached = (valid_s[0] && tag[0] == curSec+1'd1) || (valid_s[1] && tag[1] == curSec+1'd1);
	wire       freeSlot = (valid_s[0] && tag[0] == curSec) ? 1'b1 : 1'b0;   // el que no tiene el actual

	task load(input [14:0] sec, input slot);
		begin
			sd_lba <= { 17'd0, sec };
			sd_rd <= 1'b1;
			wSlot <= slot;
			valid_s[slot] <= 1'b0;
			tag[slot] <= sec;
			ld <= 1'b1;
		end
	endtask

	always @(posedge clock) begin
		ackP <= sd_ack;

		if(img_mounted) begin
			// imagen nueva (o desmontada, con tamaño 0): vacía la caché y lee el sector 0
			// las cintas de más de 16 MB no se admiten (no existen)
			fsize <= img_size[23:0];
			mounted <= img_size != 0 && img_size[31:24] == 8'd0;
			valid_s <= 2'b00;
			sd_rd <= 1'b0;
			ld <= 1'b0;
			curSec <= 15'd0;
			valid <= 1'b0;
			if(img_size != 0) begin sigOk <= 1'b1; load(15'd0, 1'b0); end
		end
		else begin
			if(ld) begin
				if(sd_ack) sd_rd <= 1'b0;
				// formato: los 8 primeros bytes del sector 0
				if(sd_ack && sd_buff_wr && tag[wSlot] == 0 && sd_buff_addr < 8 && sd_buff_dout != tzxSig(sd_buff_addr[2:0]))
					sigOk <= 1'b0;
				if(ackP && !sd_ack) begin
					valid_s[wSlot] <= 1'b1;
					ld <= 1'b0;
					if(tag[wSlot] == 0) valid <= sigOk && fsize >= 10 && mounted;
				end
			end

			if(rReq != rAck && !rBusy) begin
				if(hit0 || hit1) begin
					cRa <= { hit1, rA[8:0] };
					curSec <= reqSec;
					rLat <= 2'd2;
					rBusy <= 1'b1;
				end
				else if(!ld) load(reqSec, freeSlot);
			end
			else if(rBusy) begin
				if(rLat != 2'd0) rLat <= rLat-1'd1;
				else begin rQ <= cQ; rAck <= rReq; rBusy <= 1'b0; end
			end
			else if(!ld && mounted && curSec < lastSec && !nxtCached)
				load(curSec+1'd1, freeSlot);
		end
	end

//--- tabla de bloques ----------------------------------------------------------------------------

	// posición en el fichero de los bloques 0 .. maxKnown (se va llenando al recorrer la cinta)
	localparam integer TW = MAXBLK > 2 ? $clog2(MAXBLK) : 1;
	reg [23:0] tbl[0:MAXBLK-1];
	reg [TW-1:0] tRa, tWa;
	reg [23:0] tQ, tWd;
	reg        tWe = 1'b0;
	always @(posedge clock) begin
		if(tWe) tbl[tWa] <= tWd;
		tQ <= tbl[tRa];
	end

//--- tzxplayer -----------------------------------------------------------------------------------

	wire       req;
	reg        ack = 1'b0;
	reg        restart = 1'b0;
	reg  [7:0] data;
	wire       eot, eot48;

	// tzxplayer cuenta los milisegundos con 16 bits: con TZX_MS > 65535 (relojes de más de 65 MHz
	// con ce = 1) se le da un ce dividido entre 2, 4 u 8
	localparam integer CEDIV = TZX_MS > 262140 ? 8 : TZX_MS > 131070 ? 4 : TZX_MS > 65535 ? 2 : 1;
	reg [2:0] ceCnt = 3'd0;
	localparam [2:0] CEMAX = CEDIV-1;
	always @(posedge clock) if(ce) ceCnt <= ceCnt == CEMAX ? 3'd0 : ceCnt+1'd1;
	wire tzxCe = ce && ceCnt == 3'd0;

	tzxplayer
	#(
		.TZX_MS             (TZX_MS / CEDIV     ),
		.NORMAL_PILOT_LEN   (NORMAL_PILOT_LEN   ),
		.NORMAL_SYNC1_LEN   (NORMAL_SYNC1_LEN   ),
		.NORMAL_SYNC2_LEN   (NORMAL_SYNC2_LEN   ),
		.NORMAL_ZERO_LEN    (NORMAL_ZERO_LEN    ),
		.NORMAL_ONE_LEN     (NORMAL_ONE_LEN     ),
		.HEADER_PILOT_PULSES(HEADER_PILOT_PULSES),
		.NORMAL_PILOT_PULSES(NORMAL_PILOT_PULSES)
	)
	tzxplayer
	(
		.clk         (clock             ),
		.ce          (tzxCe             ),
		.restart_tape(restart           ),
		.host_tap_in (data              ),
		.tzx_req     (req               ),
		.tzx_ack     (ack               ),
		.loop_start  (                  ),   // los bucles los resuelve este módulo
		.loop_next   (                  ),
		.stop        (eot               ),
		.stop48k     (eot48             ),
		.cass_read   (tape              ),
		.cass_motor  (playing && motor  ),
		.cass_running(busy              )
	);

//--- longitud de cada tipo de bloque -------------------------------------------------------------

	// longitud = base + mul * (campo de n bytes en la posición off del bloque); el byte 0 es el ID
	// { base[4:0], off[4:0], n[2:0], mul[1:0] }
	function [14:0] lenInfo(input [7:0] i);
		case(i)
			8'h10: lenInfo = { 5'd5,  5'd3,  3'd2, 2'd1 };  // estándar
			8'h11: lenInfo = { 5'd19, 5'd16, 3'd3, 2'd1 };  // turbo
			8'h12: lenInfo = { 5'd5,  5'd0,  3'd0, 2'd1 };  // tono
			8'h13: lenInfo = { 5'd2,  5'd1,  3'd1, 2'd2 };  // pulsos sueltos
			8'h14: lenInfo = { 5'd11, 5'd8,  3'd3, 2'd1 };  // datos puros
			8'h15: lenInfo = { 5'd9,  5'd6,  3'd3, 2'd1 };  // grabación directa
			8'h20: lenInfo = { 5'd3,  5'd0,  3'd0, 2'd1 };  // pausa / parada
			8'h21: lenInfo = { 5'd2,  5'd1,  3'd1, 2'd1 };  // inicio de grupo
			8'h22: lenInfo = { 5'd1,  5'd0,  3'd0, 2'd1 };  // fin de grupo
			8'h23: lenInfo = { 5'd3,  5'd0,  3'd0, 2'd1 };  // salto
			8'h24: lenInfo = { 5'd3,  5'd0,  3'd0, 2'd1 };  // inicio de bucle
			8'h25: lenInfo = { 5'd1,  5'd0,  3'd0, 2'd1 };  // fin de bucle
			8'h26: lenInfo = { 5'd3,  5'd1,  3'd2, 2'd2 };  // llamada a secuencia
			8'h27: lenInfo = { 5'd1,  5'd0,  3'd0, 2'd1 };  // vuelta de la secuencia
			8'h28: lenInfo = { 5'd3,  5'd1,  3'd2, 2'd1 };  // selección
			8'h30: lenInfo = { 5'd2,  5'd1,  3'd1, 2'd1 };  // texto
			8'h31: lenInfo = { 5'd3,  5'd2,  3'd1, 2'd1 };  // mensaje
			8'h32: lenInfo = { 5'd3,  5'd1,  3'd2, 2'd1 };  // información del archivo
			8'h33: lenInfo = { 5'd2,  5'd1,  3'd1, 2'd3 };  // tipo de hardware
			8'h34: lenInfo = { 5'd9,  5'd0,  3'd0, 2'd1 };  // información de emulación (obsoleto)
			8'h35: lenInfo = { 5'd21, 5'd17, 3'd4, 2'd1 };  // información propia
			8'h40: lenInfo = { 5'd5,  5'd2,  3'd3, 2'd1 };  // snapshot (obsoleto)
			8'h5A: lenInfo = { 5'd10, 5'd0,  3'd0, 2'd1 };  // "glue" (ficheros concatenados)
			default: lenInfo = { 5'd5, 5'd1, 3'd4, 2'd1 }; // 0x18, 0x19, 0x2A, 0x2B y los
			                                                // desconocidos: longitud DWORD tras el ID
		endcase
	endfunction

	reg  [7:0] id;
	reg [14:0] li;
	// campo * mul + base, saturado a 24 bits
	wire[33:0] lF = li[4:2] == 3'd0 ? 34'd0 : { 2'd0, rdVal };
	wire[33:0] lSum = { 29'd0, li[14:10] } + (li[1:0] == 2'd1 ? lF : li[1:0] == 2'd2 ? { lF[32:0], 1'b0 } : lF+{ lF[32:0], 1'b0 });
	wire       isSig = (id >= 8'h10 && id <= 8'h15) || id == 8'h19 || id == 8'h20 || id == 8'h2A || id == 8'h2B;

//--- lectura de campos (1 a 4 bytes, little endian) -----------------------------------------------

	reg        rdBusy = 1'b0, rdWait = 1'b0;
	reg [23:0] rdAddr;
	reg [31:0] rdVal;
	reg  [2:0] rdN;
	reg  [1:0] rdK;

	task rd(input [23:0] ad, input [2:0] n);
		begin rdAddr <= ad; rdN <= n; rdK <= 2'd0; rdVal <= 32'd0; rdBusy <= 1'b1; rdWait <= 1'b0; end
	endtask

	function [16:0] sext16(input [15:0] v);
		sext16 = { v[15], v };
	endfunction

//--- recorrido de los bloques --------------------------------------------------------------------

	localparam [4:0]
		S_REQ  = 5'd0,  S_PASS = 5'd1,  S_DISP = 5'd2,  S_D1   = 5'd3,  S_D1B  = 5'd4,
		S_D2   = 5'd5,  S_D3   = 5'd6,  S_JMP  = 5'd7,  S_LOOP = 5'd8,  S_CALL = 5'd9,
		S_CALLJ= 5'd10, S_SEL0 = 5'd11, S_SEL  = 5'd12, S_SEL1 = 5'd13, S_SEL2 = 5'd14,
		S_SEL3 = 5'd15, S_GOTO = 5'd16, S_GT1  = 5'd17, S_GT2  = 5'd18, S_WALK = 5'd19,
		S_CSW1 = 5'd20, S_CSW2 = 5'd21, S_CSW3 = 5'd22, S_DIV  = 5'd23, S_DIV2 = 5'd24,
		S_PRE  = 5'd25;

	reg  [4:0] st = S_REQ;
	reg [23:0] a = 24'd0;                 // posición en el fichero
	reg [23:0] rem = 24'd0;               // bytes que quedan del bloque que se le pasa a tzxplayer
	reg        preV = 1'b0;               // byte de a ya leído
	reg  [7:0] preB = 8'd0;
	reg [23:0] L = 24'd0;                 // longitud del bloque actual
	wire[24:0] aL25 = { 1'b0, a } + { 1'b0, L };
	wire[23:0] aL = aL25[24] ? 24'hFFFFFF : aL25[23:0];   // final del bloque (saturado: fuera del fichero)
	reg [15:0] idx = 16'd0;               // número del bloque en a
	reg [15:0] maxKnown = 16'd0;          // bloques 0 .. maxKnown en la tabla
	reg [16:0] tgt = 17'd0;               // bloque destino de un salto (con signo)
	reg [15:0] gk = 16'd0;
	reg        walking = 1'b0;            // recorriendo bloques hacia el destino de un salto
	reg        ended = 1'b0;              // la cinta ha llegado al final del fichero

	reg [15:0] loopCnt = 16'd0;
	reg [23:0] loopA = 24'd0;
	reg [15:0] loopIdx = 16'd0;

	reg [15:0] callN = 16'd0, callI = 16'd0;
	reg [23:0] callA = 24'd0, callEnd = 24'd0;
	reg [15:0] callIdx = 16'd0;

	reg [23:0] selA = 24'd0, selEnd = 24'd0, ea = 24'd0;
	reg [15:0] selIdx = 16'd0;
	reg  [7:0] selPick = 8'd0, selJ = 8'd0;

	// el destino de un salto relativo: 0 no está permitido (sería un bucle infinito): sigue
	function [16:0] rel(input [15:0] base, input [15:0] r);
		rel = r == 16'd0 ? { 1'b0, base } + 17'd1 : { 1'b0, base } + sext16(r);
	endfunction

//--- CSW (0x18): pulsos -> bloques 0x13 de un pulso (+ 0x15 para pulsos largos) + 0x20 --------

	// como Fuse: duración = muestras * (3500000 / frecuencia), en T-estados
	localparam [21:0] CPU = 22'd3500000;
	localparam [1:0] IT_NONE = 2'd0, IT13 = 2'd1, IT15 = 2'd2, IT20 = 2'd3;
	localparam [2:0] P_IDLE = 3'd0, P_B = 3'd1, P_DW = 3'd2, P_MUL = 3'd3, P_SAT = 3'd4, P_SPLIT = 3'd5, P_CHK = 3'd6;

	reg        gen = 1'b0;                // sirviendo los bloques generados de un CSW
	reg [23:0] gA = 24'd0, gEnd = 24'd0;  // siguiente muestra y final del bloque
	reg        gMore = 1'b0, gRoom = 1'b0;// gA < gEnd, gA+5 <= gEnd (registrados)
	reg [15:0] gPause = 16'd0;
	reg [23:0] gRate = 24'd0;
	reg [21:0] gScale = 22'd0;
	reg        pauseDone = 1'b0;
	reg  [1:0] item = IT_NONE;            // bloque generado que se está sirviendo
	reg  [3:0] k = 4'd0;
	reg  [6:0] gCnt = 7'd0;

	// división 3500000 / frecuencia
	reg [24:0] dvR = 25'd0;
	reg [21:0] dvQ = 22'd0;
	reg  [4:0] dvI = 5'd0;
	wire[24:0] dvR2 = { dvR[23:0], CPU[dvI] };

	// cálculo del pulso siguiente mientras suena el actual
	reg  [2:0] pst = P_IDLE;
	reg [23:0] mN = 24'd0, mS = 24'd0;
	reg [24:0] mAcc = 25'd0;
	reg        mSat = 1'b0, mBig = 1'b0;  // el producto pasa de 24 bits: pulso de 4,8 s como mucho
	reg [23:0] gT = 24'd0;
	reg        tReady = 1'b0;
	reg [15:0] nP = 16'd0, cP = 16'd0;    // pulso (0x13)
	reg        nLong = 1'b0, cLong = 1'b0;// y, si pasa de 65535 T, lo que falta en muestras de 32768 T (0x15)
	reg  [3:0] nLast = 4'd0, cLast = 4'd0;
	reg  [6:0] nLen = 7'd0, cLen = 7'd0;

	wire[8:0]  gC = gT[23:15] - { 8'd0, gT[14:0] == 15'd0 };    // (gT-1) >> 15
	wire[23:0] gP = gT - { gC, 15'd0 };

	assign pos = { 8'd0, gen ? gA : a };

	task rewindAll;
		begin
			a <= 24'd0; rem <= 24'd10; idx <= 16'd0;   // la cabecera de 10 bytes se le pasa tal cual
			restart <= 1'b1; ended <= 1'b0; st <= S_REQ; rdBusy <= 1'b0; walking <= 1'b0; preV <= 1'b0;
			selecting <= 1'b0; loopCnt <= 16'd0; callN <= 16'd0;
			gen <= 1'b0; pst <= P_IDLE; tReady <= 1'b0; item <= IT_NONE;
		end
	endtask

	always @(posedge clock) begin
		restart <= 1'b0;
		tWe <= 1'b0;

		// lectura de campos
		if(rdBusy) begin
			if(!rdWait) begin
				if(rdAddr >= fsize) begin   // fuera del fichero: 0
					rdK <= rdK+1'd1; rdAddr <= rdAddr+1'd1;
					if({ 1'b0, rdK } + 1'd1 == rdN) rdBusy <= 1'b0;
				end
				else if(rReq == rAck) begin rA <= rdAddr; rReq <= ~rReq; rdWait <= 1'b1; end
			end
			else if(rReq == rAck) begin
				case(rdK)
					2'd0: rdVal[ 7: 0] <= rQ;
					2'd1: rdVal[15: 8] <= rQ;
					2'd2: rdVal[23:16] <= rQ;
					2'd3: rdVal[31:24] <= rQ;
				endcase
				rdK <= rdK+1'd1; rdAddr <= rdAddr+1'd1; rdWait <= 1'b0;
				if({ 1'b0, rdK } + 1'd1 == rdN) rdBusy <= 1'b0;
			end
		end

		// CSW: siguiente pulso
		gMore <= gA < gEnd;
		gRoom <= gA+3'd5 <= gEnd;
		case(pst)
			P_IDLE: if(gen && !tReady && !rdBusy) pst <= P_CHK;
			P_CHK: if(gMore) begin rd(gA, 3'd1); pst <= P_B; end else pst <= P_IDLE;
			P_B: if(!rdBusy) begin
				if(rdVal[7:0] != 8'd0) begin
					mN <= { 16'd0, rdVal[7:0] }; mSat <= 1'b0; gA <= gA+1'd1;
					mS <= { 2'd0, gScale }; mBig <= 1'b0; mAcc <= 25'd0; pst <= P_MUL;
				end
				else if(gRoom) begin rd(gA+1'd1, 3'd4); pst <= P_DW; end
				else begin gA <= gEnd; pst <= P_IDLE; end   // cortado
			end
			P_DW: if(!rdBusy) begin
				mN <= rdVal[23:0]; mSat <= rdVal[31:24] != 8'd0; gA <= gA+3'd5;
				mS <= { 2'd0, gScale }; mBig <= 1'b0; mAcc <= 25'd0; pst <= P_MUL;
			end
			P_MUL:
				if(mN != 24'd0) begin
					if(mN[0]) begin
						if(mBig || mAcc[24]) mSat <= 1'b1;
						mAcc <= mAcc+{ 1'b0, mS };
					end
					mN <= mN >> 1;
					mS <= mS << 1;
					if(mS[23]) mBig <= 1'b1;
				end
				else pst <= P_SAT;
			P_SAT: begin gT <= mSat || mAcc[24] ? 24'hFFFFFF : mAcc[23:0]; pst <= P_SPLIT; end
			P_SPLIT: begin
				if(gT != 24'd0) begin
					tReady <= 1'b1;
					if(gT[23:16] == 8'd0) begin nP <= gT[15:0]; nLong <= 1'b0; end
					else begin
						nP <= gP[15:0];
						nLong <= 1'b1;
						nLast <= gC[2:0] == 3'd0 ? 4'd8 : { 1'b0, gC[2:0] };
						nLen <= { 1'b0, gC[8:3] } + { 6'd0, gC[2:0] != 3'd0 };
					end
				end
				pst <= P_IDLE;
			end
			default: pst <= P_IDLE;
		endcase

		case(st)
			// tzxplayer pide un byte: solo se le da en play, así la cinta se para en el acto (en el
			// límite de un byte) con stop o con un bloque de parada, aunque tzxplayer simule la
			// inercia del motor durante 50 ms (que se mantiene para el control remoto del motor).
			// Sin petición, se adelanta trabajo: se lee el byte siguiente y, al acabar un bloque, se
			// busca el siguiente bloque con señal (resolviendo saltos, bucles...) mientras suena el
			// último pulso, para que tzxplayer no espere.
			S_REQ:
			if(gen && item == IT_NONE && !tReady && pst == P_IDLE && !gMore && (gPause == 16'd0 || pauseDone)) begin
				gen <= 1'b0; a <= gEnd; st <= S_DISP;   // fin del CSW
			end
			else if(playing && req != ack && !restart) begin
				if(gen) case(item)
					IT_NONE:
						if(tReady) begin
							tReady <= 1'b0; cP <= nP; cLong <= nLong; cLast <= nLast; cLen <= nLen;
							data <= 8'h13; ack <= req; item <= IT13; k <= 4'd1;
						end
						else if(pst == P_IDLE && !gMore && gPause != 16'd0 && !pauseDone) begin
							data <= 8'h20; ack <= req; item <= IT20; k <= 4'd1; pauseDone <= 1'b1;
						end
					IT13: begin
						ack <= req; k <= k+1'd1;
						case(k)
							4'd1: data <= 8'h01;
							4'd2: data <= cP[7:0];
							default: begin data <= cP[15:8]; item <= cLong ? IT15 : IT_NONE; k <= 4'd0; gCnt <= 7'd0; end
						endcase
					end
					IT15: begin
						ack <= req;
						if(k != 4'd9) k <= k+1'd1;
						case(k)
							4'd0: data <= 8'h15;
							4'd1: data <= 8'h00;              // muestras de 32768 T
							4'd2: data <= 8'h80;
							4'd3: data <= 8'h00;              // sin pausa
							4'd4: data <= 8'h00;
							4'd5: data <= { 4'd0, cLast };
							4'd6: data <= { 1'b0, cLen };
							4'd7: data <= 8'h00;
							4'd8: data <= 8'h00;
							default: begin
								data <= {8{tape}};              // mantiene el nivel
								if(gCnt == cLen-1'd1) item <= IT_NONE; else gCnt <= gCnt+1'd1;
							end
						endcase
					end
					IT20: begin
						ack <= req; k <= k+1'd1;
						if(k == 4'd1) data <= gPause[7:0];
						else begin data <= gPause[15:8]; item <= IT_NONE; end
					end
				endcase
				else if(rem != 24'd0 && a >= fsize) begin playing <= 1'b0; ended <= 1'b1; end   // cortado
				else if(rem != 24'd0) begin
					if(preV) begin data <= preB; ack <= req; a <= a+1'd1; rem <= rem-1'd1; preV <= 1'b0; end
					else if(!rdBusy) begin rd(a, 3'd1); st <= S_PASS; end
				end
				else if(!rdBusy) st <= S_DISP;
			end
			else if(!gen && !restart && !rdBusy && !ended) begin
				if(rem != 24'd0) begin if(!preV && a < fsize) begin rd(a, 3'd1); st <= S_PRE; end end
				else if(a < fsize) st <= S_DISP;
			end

			S_PASS: if(!rdBusy) begin data <= rdVal[7:0]; ack <= req; a <= a+1'd1; rem <= rem-1'd1; st <= S_REQ; end
			S_PRE:  if(!rdBusy) begin preB <= rdVal[7:0]; preV <= 1'b1; st <= S_REQ; end

			// bloque nuevo: ID y longitud
			S_DISP:
				if(a >= fsize) begin   // final de la cinta, cuando tzxplayer pida el bloque siguiente
					if(playing && req != ack) begin playing <= 1'b0; ended <= 1'b1; end
					walking <= 1'b0; st <= S_REQ;
				end
				else begin rd(a, 3'd1); st <= S_D1; end
			S_D1: if(!rdBusy) begin id <= rdVal[7:0]; li <= lenInfo(rdVal[7:0]); st <= S_D1B; end
			S_D1B: begin if(li[4:2] != 3'd0) rd(a+li[9:5], li[4:2]); st <= S_D2; end
			S_D2: if(!rdBusy) begin L <= lSum[33:24] != 10'd0 ? 24'hFFFFFF : lSum[23:0]; st <= S_D3; end
			S_D3: begin
				if(idx == maxKnown && idx+1'd1 < MAXBLK) begin
					tWe <= 1'b1; tWa <= idx[TW-1:0]+1'd1; tWd <= aL; maxKnown <= idx+1'd1;
				end
				if(walking) begin a <= aL; idx <= idx+1'd1; st <= S_WALK; end
				else if(isSig) begin rem <= L; idx <= idx+1'd1; st <= S_REQ; end
				else case(id)
					8'h18: if(CSW) begin idx <= idx+1'd1; gEnd <= aL; rd(a+3'd5, 3'd2); st <= S_CSW1; end
					       else begin a <= aL; idx <= idx+1'd1; st <= S_DISP; end
					8'h23: begin rd(a+1'd1, 3'd2); st <= S_JMP; end
					8'h24: begin rd(a+1'd1, 3'd2); st <= S_LOOP; end
					8'h25: begin
						if(loopCnt > 16'd1) begin loopCnt <= loopCnt-1'd1; a <= loopA; idx <= loopIdx; end
						else begin a <= aL; idx <= idx+1'd1; end
						st <= S_DISP;
					end
					8'h26: begin callIdx <= idx; callA <= a; callEnd <= aL; rd(a+1'd1, 3'd2); st <= S_CALL; end
					8'h27:
						if(callN != 16'd0) begin
							if(callI+1'd1 < callN) begin
								callI <= callI+1'd1; rd(callA+2'd3+{ 7'd0, callI+1'd1, 1'b0 }, 3'd2); st <= S_CALLJ;
							end
							else begin callN <= 16'd0; a <= callEnd; idx <= callIdx+1'd1; st <= S_DISP; end
						end
						else begin a <= aL; idx <= idx+1'd1; st <= S_DISP; end
					8'h28: begin selIdx <= idx; selA <= a; selEnd <= aL; rd(a+2'd3, 3'd1); st <= S_SEL0; end
					default: begin a <= aL; idx <= idx+1'd1; st <= S_DISP; end   // se salta
				endcase
			end

			S_JMP: if(!rdBusy) begin tgt <= rel(idx, rdVal[15:0]); st <= S_GOTO; end
			S_LOOP: if(!rdBusy) begin
				loopCnt <= rdVal[15:0]; loopA <= aL; loopIdx <= idx+1'd1;
				a <= aL; idx <= idx+1'd1; st <= S_DISP;
			end
			S_CALL: if(!rdBusy) begin
				callN <= rdVal[15:0]; callI <= 16'd0;
				if(rdVal[15:0] == 16'd0) begin a <= aL; idx <= idx+1'd1; st <= S_DISP; end
				else begin rd(a+2'd3, 3'd2); st <= S_CALLJ; end
			end
			S_CALLJ: if(!rdBusy) begin tgt <= rel(callIdx, rdVal[15:0]); st <= S_GOTO; end

			// selección: para la cinta hasta que se elija una opción (select) o se pulse play
			S_SEL0: if(!rdBusy && playing && req != ack) begin sel_count <= rdVal[7:0]; playing <= 1'b0; selecting <= 1'b1; st <= S_SEL; end
			S_SEL: if(selE || playing) begin
				selecting <= 1'b0;
				if(sel_count == 8'd0) begin a <= selEnd; idx <= selIdx+1'd1; st <= S_DISP; end
				else begin
					selPick <= selE && sel_index < sel_count ? sel_index : 8'd0;
					selJ <= 8'd0; ea <= selA+3'd4; st <= S_SEL1;
				end
			end
			S_SEL1: if(!rdBusy) begin
				if(selJ == selPick) begin rd(ea, 3'd2); st <= S_SEL3; end
				else begin rd(ea+2'd2, 3'd1); st <= S_SEL2; end
			end
			S_SEL2: if(!rdBusy) begin ea <= ea+2'd3+rdVal[7:0]; selJ <= selJ+1'd1; st <= S_SEL1; end
			S_SEL3: if(!rdBusy) begin tgt <= rel(selIdx, rdVal[15:0]); st <= S_GOTO; end

			// ir al bloque tgt: desde la tabla, y si no está, recorriendo los bloques
			S_GOTO:
				if(tgt[16]) begin a <= fsize; st <= S_DISP; end   // antes del principio: se acaba la cinta
				else begin
					gk <= tgt[15:0] <= maxKnown ? tgt[15:0] : maxKnown;
					tRa <= tgt[15:0] <= maxKnown ? tgt[TW-1:0] : maxKnown[TW-1:0];
					st <= S_GT1;
				end
			S_GT1: st <= S_GT2;
			S_GT2: begin a <= tQ; idx <= gk; walking <= 1'b1; st <= S_WALK; end
			S_WALK: begin if(idx == tgt[15:0]) walking <= 1'b0; st <= S_DISP; end

			// CSW: cabecera y escala
			S_CSW1: if(!rdBusy) begin gPause <= rdVal[15:0]; rd(a+3'd7, 3'd3); st <= S_CSW2; end
			S_CSW2: if(!rdBusy) begin gRate <= rdVal[23:0]; rd(a+4'd10, 3'd1); st <= S_CSW3; end
			S_CSW3: if(!rdBusy) begin
				// solo RLE (1); Z-RLE (2) necesitaría descomprimir zlib: se salta
				if(rdVal[7:0] != 8'd1 || gRate == 24'd0) begin a <= gEnd; st <= S_DISP; end
				else begin dvR <= 25'd0; dvQ <= 22'd0; dvI <= 5'd21; st <= S_DIV; end
			end
			S_DIV: begin
				if(dvR2 >= { 1'b0, gRate }) begin dvR <= dvR2-{ 1'b0, gRate }; dvQ[dvI] <= 1'b1; end
				else dvR <= dvR2;
				if(dvI == 5'd0) st <= S_DIV2; else dvI <= dvI-1'd1;
			end
			S_DIV2: begin
				gScale <= dvQ; gA <= a+4'd15; gMore <= 1'b1; gen <= 1'b1; item <= IT_NONE; tReady <= 1'b0;
				pauseDone <= 1'b0; pst <= P_IDLE; st <= S_REQ;
			end
			default: st <= S_REQ;
		endcase

		// mandos
		if(img_mounted || rewE) begin
			// imagen nueva o rebobinar: al principio y parada
			rewindAll;
			playing <= 1'b0;
			if(img_mounted) begin maxKnown <= 16'd0; tWe <= 1'b1; tWa <= {TW{1'b0}}; tWd <= 24'd10; end
		end
		else if(playE && valid && mounted) begin
			playing <= 1'b1;
			if(ended) rewindAll;
		end
		else if(selE && selecting) playing <= 1'b1;
		else if(stopE || eot || (eot48 && stop48)) playing <= 1'b0;
	end

//-------------------------------------------------------------------------------------------------
endmodule
//-------------------------------------------------------------------------------------------------
