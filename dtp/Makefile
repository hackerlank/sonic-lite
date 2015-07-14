QUARTUS_SH=$(shell which quartus_sh)
ROOTDIR=$(realpath .)
CONNECTALDIR?=$(ROOTDIR)/../../connectal/
IPDIR?=$(ROOTDIR)/../../fpgamake-cache/$(shell basename `/bin/pwd`)/
PROJTOP?=$(ROOTDIR)

CONNECTALFLAGS += --bscflags="-p +:$(PROJTOP)/../hw/lib/bsv:$(PROJTOP)/../hw/bsv:$(PROJTOP)/../hw/generated"
CONNECTALFLAGS += --bscflags="+RTS -K46777216 -RTS -demote-errors G0066:G0045 -suppress-warnings G0046:G0020:S0015:S0080:S0039 -steps-max-intervals 20"

S2H_INTERFACES=DtpUserRequest:DtpUser.request
H2S_INTERFACES=DtpUser:DtpUserIndication
AUTOTOP= --interface pins:DtpUser.dtp
BSVFILES=$(PROJTOP)/../hw/bsv/DtpUser.bsv
CPPFILES=$(PROJTOP)/../sw/test-dtp.cpp
NUMBER_OF_MASTERS =0
PIN_BINDINGS?=PCIE:PCIE LED:LED OSC:OSC SFPA:SFPA SFPB:SFPB SFPC:SFPC SFPD:SFPD SFP:SFP I2C:CLOCK BUTTON:BUTTON SW:SW
PIN_TYPE = DtpIfc
EXPORT_TYPE = PinsTopIfc
CONNECTALFLAGS += -C $(PROJTOP)/mkDtpTop.sdc
CONNECTALFLAGS += --xci=$(IPDIR)/$(BOARD)/synthesis/altera_mac/altera_mac.qip
CONNECTALFLAGS += --xci=$(IPDIR)/$(BOARD)/synthesis/pll_156/altera_pll_156.qip
CONNECTALFLAGS += --xci=$(IPDIR)/$(BOARD)/synthesis/sv_10g_pma/sv_10g_pma.qip
CONNECTALFLAGS += --xci=$(IPDIR)/$(BOARD)/synthesis/altera_clkctrl/altera_clkctrl.qip
CONNECTALFLAGS += --verilog=$(PROJTOP)/../hw/verilog/si570/
#CONNECTALFLAGS += --chipscope=$(PROJTOP)/hw/stp/rx_debug.stp
CONNECTALFLAGS += --tcl=$(PROJTOP)/../boards/de5_extra.qsf
CONNECTALFLAGS += -D DtpVersion=$(shell date +"%y%m%d%H%M")
CONNECTALFLAGS += --pinfo=$(PROJTOP)/../boards/dtp_synth.json

prebuild::
ifneq (, $(QUARTUS_SH))
	#(cd $(BOARD); BUILDCACHE_CACHEDIR=$(BUILDCACHE_CACHEDIR) $(BUILDCACHE) $(QUARTUS_SH) -t $(PROJTOP)/hw/scripts/connectal-simu-pcietb.tcl)
	(cd $(BOARD); BUILDCACHE_CACHEDIR=$(BUILDCACHE_CACHEDIR) $(BUILDCACHE) $(QUARTUS_SH) -t $(CONNECTALDIR)/scripts/connectal-synth-pll.tcl)
	(cd $(BOARD); BUILDCACHE_CACHEDIR=$(BUILDCACHE_CACHEDIR) $(BUILDCACHE) $(QUARTUS_SH) -t $(PROJTOP)/../hw/scripts/connectal-synth-mac.tcl)
	(cd $(BOARD); BUILDCACHE_CACHEDIR=$(BUILDCACHE_CACHEDIR) $(BUILDCACHE) $(QUARTUS_SH) -t $(PROJTOP)/../hw/scripts/connectal-synth-eth.tcl)
endif

include $(CONNECTALDIR)/Makefile.connectal