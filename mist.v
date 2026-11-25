//-------------------------------------------------------------------------------------------------
module mist
//-------------------------------------------------------------------------------------------------
#
(
	RGBW = 8
)
(
	input  wire       clock,
	input  wire       pe24M,
	input  wire       pe12M,
	input  wire       pe6M0,
	input  wire       reset,

	input  wire       spiCk,
	input  wire       spiSs1,
	input  wire       spiSs2,
	input  wire       spiSs3,
	input  wire       spiMosi,
	output wire       spiMiso,

	output wire       ready,
	output wire[63:0] status,

	input  wire       r,
	input  wire       g,
	input  wire       b,
	input  wire       hsync,
	input  wire       vsync,

	output wire[RGBW*3-1:0] rgb,
	output wire[ 1:0] sync,

	output wire       ps2kCk,
	output wire       ps2kD,

	output wire[ 7:0] joy0,
	output wire[ 7:0] joy1,

	output wire       dioE,
	output wire[26:0] dioA,
	output wire[ 7:0] dioD,
	output wire       dioW,

	input  wire[ 1:0] fdcA,
	input  wire[ 7:0] fdcD,
	output wire[ 7:0] fdcQ,
	input  wire       fdcR,
	input  wire       fdcW,
	input  wire       fdcSel,
	input  wire       fdcSide,

	output wire       tzxEar,
	output wire       tzxBusy,
	input  wire       tzxPlay,
	input  wire       tzxStop,
	input  wire       tzxMotor
);
//--- config --------------------------------------------------------------------------------------

	localparam confStr =
	{
		"Lynx128;;",
		"-;",
		"S0U,LDF,Mount LDF;",
		"S1U,TZX,Mount TZX;",
		"-;",
		"O5,Floppy,On,Off;",
		"O4,Tape sound,Off,On;",
		"-;",
		"T0,Reset;",
		"V,V2.0,2026.11.25;",
	};

//--- user io -------------------------------------------------------------------------------------

	wire[31:0] joystick_0;
	wire[31:0] joystick_1;

	wire[ 1:0] sdRd;
	wire[ 1:0] sdWr;
	wire[ 1:0] sdAck;
	wire       sdAckCf;
	wire[31:0] sdLba = sdRd[1] ? tzxLba : fdcLba;
	wire[16:0] sdA;
	wire[ 7:0] sdD;
	wire[ 7:0] sdQ;
	wire       sdW;
	wire[ 1:0] imgM;
	wire[63:0] imgSz;

	wire novga;

	user_io #(.STRLEN(116), .SD_IMAGES(2), .FEATURES(32'h2000)) user_io
	(
		.conf_str        (confStr),
		.conf_addr       (),
		.conf_chr        (8'd0),
		.clk_sys         (clock  ),
		.clk_sd          (clock  ),
		.SPI_CLK         (spiCk  ),
		.SPI_SS_IO       (spiSs1 ),
		.SPI_MOSI        (spiMosi),
		.SPI_MISO        (spiMiso),
		.ps2_kbd_clk     (ps2kCk ),
		.ps2_kbd_data    (ps2kD  ),
		.ps2_kbd_clk_i   (1'b0),
		.ps2_kbd_data_i  (1'b0),
		.ps2_mouse_clk   (),
		.ps2_mouse_data  (),
		.ps2_mouse_clk_i (1'b0),
		.ps2_mouse_data_i(1'b0),
		.joystick_0      (joystick_0),
		.joystick_1      (joystick_1),
		.joystick_2      (),
		.joystick_3      (),
		.joystick_4      (),
		.sd_rd           (sdRd   ),
		.sd_wr           (sdWr   ),
		.sd_ack          (),
		.sd_ack_conf     (sdAckCf),
		.sd_ack_x        (sdAck  ),
		.sd_cnt          (8'd0   ),
		.sd_lba          (sdLba  ),
		.sd_conf         (),
		.sd_sdhc         (1'b1   ),
		.sd_buff_addr    (sdA    ),
		.sd_din          (sdD    ),
		.sd_din_strobe   (),
		.sd_dout         (sdQ    ),
		.sd_dout_strobe  (sdW    ),
		.img_mounted     (imgM   ),
		.img_size        (imgSz  ),
		.rtc             (),
		.leds            (8'd0),
		.ypbpr           (),
		.status          (status ),
		.buttons         (),
		.switches        (),
		.no_csync        (),
		.core_mod        (),
		.key_pressed     (),
		.key_extended    (),
		.key_code        (),
		.key_strobe      (),
		.kbd_out_data    (8'd0),
		.kbd_out_strobe  (1'b0),
		.mouse_x         (),
		.mouse_y         (),
		.mouse_flags     (),
		.mouse_strobe    (),
		.mouse_z         (),
		.mouse_idx       (),
		.serial_data     (8'd0),
		.serial_strobe   (1'd0),
		.i2c_start       (),
		.i2c_read        (),
		.i2c_addr        (),
		.i2c_subaddr     (),
		.i2c_dout        (),
		.i2c_din         (8'd0),
		.i2c_ack         (1'b0),
		.i2c_end         (1'b0),
		.joystick_analog_0(),
		.joystick_analog_1(),
		.scandoubler_disable(novga)
	);

//--- data io -------------------------------------------------------------------------------------

	wire[7:0] dioIx;

	data_io	data_io
	(
		.clk_sys       (clock  ),
		.SPI_SCK       (spiCk  ),
		.SPI_SS2       (spiSs2 ),
		.SPI_SS4       (1'b1   ),
		.SPI_DI        (spiMosi),
		.SPI_DO        (spiMiso),
		.clkref_n      (1'b0   ),
		.ioctl_download(dioE   ),
		.ioctl_addr    (dioA   ),
		.ioctl_din     (8'd0   ),
		.ioctl_dout    (dioD   ),
		.ioctl_wr      (dioW   ),
		.ioctl_upload  (),
		.ioctl_index   (dioIx  ),
		.ioctl_fileext (),
		.ioctl_filesize(),
		.QCSn          (1'b1),
		.QSCK          (1'b1),
		.QDAT          (4'hF),
		.hdd_clk       (1'b0),
		.hdd_cmd_req   (1'b0),
		.hdd_cdda_req  (1'b0),
		.hdd_dat_req   (1'b0),
		.hdd_cdda_wr   (),
		.hdd_status_wr (),
		.hdd_addr      (),
		.hdd_wr        (),
		.hdd_data_out  (),
		.hdd_data_in   (16'd0),
		.hdd_data_rd   (),
		.hdd_data_wr   (),
		.hdd0_ena      (),
		.hdd1_ena      ()
	);

//--- fdc -----------------------------------------------------------------------------------------

	reg imgMp;
	always @(posedge clock) imgMp <= imgM[0];

	reg fdcDisk;
	always @(posedge clock) if(imgM[0] && !imgMp) fdcDisk <= |imgSz;

	wire[31:0] fdcLba;
	wire fdcRdy = fdcSel && fdcDisk;
	wire fdcBusy;
	wire fdcPrep;

	wd1793 #(.EDSK(0), .RWMODE(1)) wd1793
	(
		.clk_sys            (clock   ), // input        clk_sys,     // sys clock
		.ce                 (pe6M0   ), // input        ce,          // ce at CPU clock rate
		.reset              (~reset  ), // input        reset,	     // async reset
		.io_en              (1'b1    ), // input        io_en,
		.rd                 (fdcR    ), // input        rd,          // i/o read
		.wr                 (fdcW    ), // input        wr,          // i/o write
		.addr               (fdcA    ), // input  [1:0] addr,        // i/o port addr
		.din                (fdcD    ), // input  [7:0] din,         // i/o data in
		.dout               (fdcQ    ), // output [7:0] dout,        // i/o data out
		.drq                (        ), // output       drq,         // DMA request
		.intrq              (        ), // output       intrq,
		.busy               (        ), // output       busy,
		.wp                 (1'b0    ), // input        wp,          // write protect
		.size_code          (3'd4    ), // input  [2:0] size_code,
		.layout             (1'b1    ), // input        layout,      // 0 = Track-Side-Sector, 1 - Side-Track-Sector
		.side               (fdcSide ), // input        side,
		.ready              (fdcRdy  ), // input        ready,
		// SD access (RWMODE == 1)
		.img_mounted        (imgM[0] ), // input        img_mounted, 			// signaling that new image has been mounted
		.img_mounted_overide(1'b0    ), // input        img_mounted_overide,   // SRH - used to always load img_size (& layout) per clock [img_mounted occurs at higher level]
		.img_size           (imgSz   ), // input [63:0] img_size,    // size of image in bytes.
		.prepare            (        ), // output       prepare,
		.sd_lba             (fdcLba  ), // output[31:0] sd_lba,
		.sd_rd              (sdRd[0] ), // output reg   sd_rd,
		.sd_wr              (sdWr[0] ), // output reg   sd_wr,
		.sd_ack             (sdAck[0]), // input        sd_ack,
		.sd_buff_addr       (sdA[8:0]), // input  [8:0] sd_buff_addr,
		.sd_buff_dout       (sdQ     ), // input  [7:0] sd_buff_dout,
		.sd_buff_din        (sdD     ), // output [7:0] sd_buff_din,
		.sd_buff_wr         (sdW     ), // input        sd_buff_wr,
		// RAM access (RWMODE == 0)
		.input_active       ( 1'd0   ), // input        input_active,
		.input_addr         (20'd0   ), // input [19:0] input_addr,
		.input_data         ( 8'd0   ), // input  [7:0] input_data,
		.input_wr           ( 1'd0   ), // input        input_wr,
		.buff_addr          (        ), // output[19:0] buff_addr,	  // buffer RAM address
		.buff_read          (        ), // output       buff_read,	  // buffer RAM read enable
		.buff_din           ( 8'd0   )  // input  [7:0] buff_din,     // buffer RAM data input
	);

//--- tzx -----------------------------------------------------------------------------------------

	wire[31:0] tzxLba;

	tzx #(.TZX_MS(48000)) tzx
	(
		.clock       (clock   ),
		.ce          (1'b1    ),
		.img_mounted (imgM[1] ),
		.img_size    (imgSz[31:0]),
		.sd_lba      (tzxLba  ),
		.sd_rd       (sdRd[1] ),
		.sd_ack      (sdAck[1]),
		.sd_buff_addr(sdA[8:0]),
		.sd_buff_dout(sdQ     ),
		.sd_buff_wr  (sdW     ),
		.play        (tzxPlay ),
		.stop        (tzxStop ),
		.rewind      (tzxStop ),
		.motor       (tzxMotor),
		.stop48      (1'b0    ),
		.select      (1'b0    ),
		.sel_index   (8'd0    ),
		.busy        (tzxBusy ),
		.tape        (tzxEar  ),
		.playing     (        ),
		.valid       (        ),
		.selecting   (        ),
		.sel_count   (        ),
		.pos         (        ),
		.size        (        ),
		.loading     (        )
	);

//--- osd -----------------------------------------------------------------------------------------

	wire[RGBW*3-1:0] rgbosd;

	osd #(.OSD_AUTO_CE(1'b0), .OUT_COLOR_DEPTH(RGBW), .BIG_OSD(1'b1)) osd
	(
		.clk_sys(clock  ),
		.ce     (pe12M  ),
		.SPI_SCK(spiCk  ),
		.SPI_SS3(spiSs3 ),
		.SPI_DI (spiMosi),
		.rotate (2'd0   ),
		.HBlank (1'b0   ),
		.VBlank (1'b0   ),
		.HSync  (hsync  ),
		.VSync  (vsync  ),
		.R_in   ({RGBW{ r }}),
		.G_in   ({RGBW{ g }}),
		.B_in   ({RGBW{ b }}),
		.R_out  (rgbosd[RGBW*3-1:RGBW*2]),
		.G_out  (rgbosd[RGBW*2-1:RGBW*1]),
		.B_out  (rgbosd[RGBW*1-1:RGBW*0]),
		.osd_enable()
	);

//--- scandoubler ---------------------------------------------------------------------------------

	scandoubler #(.HCW(11), .RGBW(RGBW*3)) scandoubler
	(
		.clock   (clock  ),
		.novga   (novga  ),
		.ice     (pe12M  ),
		.isync   ({ vsync, hsync }),
		.irgb    (rgbosd ),
		.oce     (pe24M  ),
		.osync   (sync   ),
		.orgb    (rgb    )
	);

//-------------------------------------------------------------------------------------------------

	wire romIo = dioE && dioIx[5:0] == 0;

	reg romIoPre = 0;
	always @(posedge clock) romIoPre <= romIo;

	reg romReady = 1'b0;
	always @(posedge clock) if(!romReady && !romIo && romIoPre) romReady <= 1'b1;

	assign joy0 = ~{ 2'b00, joystick_1[4], 1'b0, joystick_1[0], joystick_1[1], joystick_1[2], joystick_1[3] };
	assign joy1 = ~{ 2'b00, joystick_0[4], 1'b0, joystick_0[0], joystick_0[1], joystick_0[2], joystick_0[3] };

	assign ready = romReady;

//-------------------------------------------------------------------------------------------------
endmodule
//-------------------------------------------------------------------------------------------------
