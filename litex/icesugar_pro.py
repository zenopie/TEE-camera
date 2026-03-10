# iCESugar Pro (iCE40UP5K SG48) LiteX Platform Definition
# Targets the iCESugar Pro board with 12 MHz oscillator, USB-UART via FT232,
# 4x SPRAM blocks (128 KB unified), and PMOD connector for OV2640 camera stub.

from litex.build.generic_platform import *
from litex.build.lattice import LatticePlatform

# ---------------------------------------------------------------------------
# Pin / IO definitions
# ---------------------------------------------------------------------------
_io = [
    # ------------------------------------------------------------------
    # On-board 12 MHz oscillator
    # ------------------------------------------------------------------
    ("clk12", 0, Pins("35"), IOStandard("SB_LVCMOS")),

    # ------------------------------------------------------------------
    # RGB LED (active-low on iCESugar Pro)
    # ------------------------------------------------------------------
    ("user_led", 0, Pins("40"), IOStandard("SB_LVCMOS")),
    ("user_led", 1, Pins("41"), IOStandard("SB_LVCMOS")),
    ("user_led", 2, Pins("39"), IOStandard("SB_LVCMOS")),

    # ------------------------------------------------------------------
    # USB-UART via FT232HL
    # pin 14 = TX (FPGA drives), pin 17 = RX (FPGA listens)
    # ------------------------------------------------------------------
    ("serial", 0,
        Subsignal("tx", Pins("14")),
        Subsignal("rx", Pins("17")),
        IOStandard("SB_LVCMOS"),
    ),

    # ------------------------------------------------------------------
    # SPI Flash (W25Q64)  – quad mode capable
    # ------------------------------------------------------------------
    ("spiflash4x", 0,
        Subsignal("cs_n", Pins("16"), Misc("PULLUP")),
        Subsignal("clk",  Pins("15")),
        Subsignal("dq",   Pins("14 17 25 26")),
        IOStandard("SB_LVCMOS"),
    ),
    # Single-lane alias used by LiteX SPI-flash driver
    ("spiflash", 0,
        Subsignal("cs_n", Pins("16"), Misc("PULLUP")),
        Subsignal("clk",  Pins("15")),
        Subsignal("mosi", Pins("14")),
        Subsignal("miso", Pins("17")),
        IOStandard("SB_LVCMOS"),
    ),

    # ------------------------------------------------------------------
    # PMOD connector – wired to OV2640 / camera stub
    # PMOD:0 = PCLK   PMOD:1 = VSYNC  PMOD:2 = HREF
    # PMOD:3..7 = D0..D4  (lower 5 bits of 8-bit parallel bus;
    #                       D5..D7 sampled on second PMOD if populated)
    # ------------------------------------------------------------------
    ("pmod_camera", 0,
        Subsignal("pclk",  Pins("PMOD:0")),
        Subsignal("vsync", Pins("PMOD:1")),
        Subsignal("href",  Pins("PMOD:2")),
        Subsignal("data",  Pins("PMOD:3 PMOD:4 PMOD:5 PMOD:6 PMOD:7")),
        IOStandard("SB_LVCMOS"),
    ),

    # ------------------------------------------------------------------
    # I2C for camera configuration (SCCB-compatible)
    # ------------------------------------------------------------------
    ("i2c", 0,
        Subsignal("scl", Pins("PMOD:6")),
        Subsignal("sda", Pins("PMOD:7")),
        IOStandard("SB_LVCMOS"),
    ),
]

# ---------------------------------------------------------------------------
# Connector definitions
# ---------------------------------------------------------------------------
_connectors = [
    # PMOD A – 8 signal pins (50-mil header, two rows of 6)
    ("PMOD", "28 31 34 38 43 44 45 47"),
]

# ---------------------------------------------------------------------------
# Platform class
# ---------------------------------------------------------------------------
class Platform(LatticePlatform):
    """LiteX platform for the iCESugar Pro (iCE40UP5K-SG48).

    Resources
    ---------
    * 5280 LUTs (iCE40UP5K)
    * 4 × 32 Kx16 SPRAM  = 128 KB on-chip SRAM  (no external SDRAM/DDR)
    * 128 Kb embedded BRAM (EBR) spread across 30 × 4 Kbit blocks
    * PLL (SB_PLL40_CORE)
    * 12 MHz on-board oscillator
    """

    default_clk_name   = "clk12"
    default_clk_period = 1e9 / 12e6   # ns per cycle ≈ 83.33 ns

    def __init__(self):
        LatticePlatform.__init__(
            self,
            "ice40up5k-sg48",
            _io,
            _connectors,
            toolchain="icestorm",
        )

    def create_programmer(self):
        from litex.build.lattice.programmer import IceSugarProgrammer
        return IceSugarProgrammer()
