# all: compile sim verdi
.PHONY: env compile run sim selfcheck verdi clean

TOP = tb_SPI_Flash
SIM_DIR = $(ROOT_PATH)/sim
FILE_LIST = ../filelist/sim.f
FSDB = spi_flash.fsdb

VCS = vcs
VERDI = verdi

VCS_FLAGS = -full64 +v2k -sverilog \
            -timescale=1ns/1ps \
            -debug_access+all -debug_region+cell+encrypt \
            +define+DUMP_FSDB

VERDI_PLI = -P $(VERDI_HOME)/share/PLI/VCS/LINUX64/novas.tab \
              $(VERDI_HOME)/share/PLI/VCS/LINUX64/pli.a

#-----------------------------------------------------------------------
env:
	@echo "ROOT_PATH = $(ROOT_PATH)"
	@echo "SIM_DIR   = $(SIM_DIR)"
	@echo "FILE_LIST = $(FILE_LIST)"
	@echo "TOP       = $(TOP)"
	@echo "VERDI_HOME= $(VERDI_HOME)"

#-----------------------------------------------------------------------
compile:
	@if [ -z "$(ROOT_PATH)" ]; then \
		echo "ERROR: ROOT_PATH is empty. Please run: source scripts/setup_env.sh"; \
		exit 1; \
	fi
	@if [ -z "$(VERDI_HOME)" ]; then \
		echo "ERROR: VERDI_HOME is empty. Please load Verdi environment first."; \
		exit 1; \
	fi
	@mkdir -p $(SIM_DIR)
	cd $(SIM_DIR) && \
	$(VCS) -f $(FILE_LIST) \
	$(VCS_FLAGS) \
	$(VERDI_PLI) \
	-l compile.log \
	-o simv | tee vcs.log

#-----------------------------------------------------------------------
run:
	cd $(SIM_DIR) && ./simv +DUMP_FSDB | tee sim.log

#-----------------------------------------------------------------------
sim: compile run

#-----------------------------------------------------------------------
selfcheck: sim
	grep -q "RTL SELF CHECK PASS" $(SIM_DIR)/sim.log && \
	echo "RTL selfcheck result: PASS"

#-----------------------------------------------------------------------
verdi:
	cd $(SIM_DIR) && \
	$(VERDI) -sv -f $(FILE_LIST) -top $(TOP) -ssf $(FSDB) &

#-----------------------------------------------------------------------
clean:
	cd $(SIM_DIR) && \
	rm -rf csrc DVEfiles novas* *.log simv* *fsdb* ucli.key *.vpd verdiLog
