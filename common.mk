# =========================================================
# Shared Dual-Simulator Build System
# =========================================================

# Allow the local Makefile to override these variables, but set defaults
VARIANTS ?= 0
VARIANT ?= $(firstword $(VARIANTS))
INCDIRS ?= +incdir+rtl
SIM     ?= vsim
FILELIST ?= rtl.f

# Automatically discover all testbenches in the local tb/ folder
TESTBENCHES = $(patsubst tb/%.sv,%,$(wildcard tb/*_tb.sv))

# Find where THIS common.mk file is located so we can find the scripts
BUILD_TOOLS_DIR := $(dir $(lastword $(MAKEFILE_LIST)))

VERILATOR_FLAGS = --binary -j 0 --timing --trace -Wall -Wno-fatal

# =====================
# STANDARD TARGETS
# =====================
all: run_all

.PHONY: run_all clean run_%

# Generate the flat filelist using the central script
build.f: $(FILELIST)
	@echo "=== Flattening hierarchical filelists ==="
	python3 $(BUILD_TOOLS_DIR)/scripts/flatten_f.py $(FILELIST) > build.f

run_all: build.f
	@for tb in $(TESTBENCHES); do \
		$(MAKE) run_$$tb SIM=$(SIM); \
	done

run_%: build.f
	@for v in $(VARIANTS); do \
		$(MAKE) run_single_$* SIM=$(SIM) VARIANT=$$v; \
	done

run_single_%: build.f
	@echo "=== Running $* with $(SIM) (Variant $(VARIANT)) ==="
ifeq ($(SIM), verilator)
	verilator --version
	verilator $(VERILATOR_FLAGS) $(INCDIRS) -GLASCON_VARIANT=$(VARIANT) --top-module $* -f build.f tb/$*.sv
	bash -c "set -o pipefail; ./obj_dir/V$* 2>&1 | tee $*_variant$(VARIANT).log"
else
	vlib work
	vlog -work work -sv $(INCDIRS) -f build.f tb/$*.sv

	@echo 'vcd file $*_variant$(VARIANT).vcd' > run_$*.macro
	@echo 'vcd add -r /$*/*' >> run_$*.macro
	@echo 'run -all' >> run_$*.macro
	@echo 'quit' >> run_$*.macro
	vsim -c -gLASCON_VARIANT=$(VARIANT) -do run_$*.macro work.$* -l $*_variant$(VARIANT).log
	@rm -f run_$*.macro
endif

# =====================
# SYNTHESIS TARGETS
# =====================
TOP_MODULE ?= $(basename $(notdir $(shell grep -v '^\s*\#' $(FILELIST) | grep -v '^\s*$$' | grep -v '^-' | tail -1)))
SYNTH_MODULES ?= $(TOP_MODULE)
SYNTH_OUTDIR ?= ./synth/metrics/
SYNTH_LOGDIR ?= ./synth/build/logs/

.PHONY: synth

# Run all synthesis targets
synth:
	@for mod in $(SYNTH_MODULES); do \
		$(MAKE) synth_single_fpga TOP_MODULE=$$mod; \
		$(MAKE) synth_single_asic TOP_MODULE=$$mod; \
	done

.PHONY: get_sky130
get_sky130:
	@bash $(BUILD_TOOLS_DIR)/scripts/get_sky130.sh

# Individual synthesis targets
synth_fpga: build.f
	@for mod in $(SYNTH_MODULES); do \
		$(MAKE) synth_single_fpga TOP_MODULE=$$mod; \
	done

synth_asic: build.f get_sky130
	@for mod in $(SYNTH_MODULES); do \
		$(MAKE) synth_single_asic TOP_MODULE=$$mod; \
	done

synth_single_fpga: build.f
	@echo "=== Running Yosys Synthesis (fpga) for $(TOP_MODULE) ==="
	python3 $(BUILD_TOOLS_DIR)/scripts/synth_metrics.py --top $(TOP_MODULE) --run fpga --outdir $(SYNTH_OUTDIR) --logdir $(SYNTH_LOGDIR)

synth_single_asic: build.f get_sky130
	@echo "=== Running Yosys Synthesis (asic) for $(TOP_MODULE) ==="
	python3 $(BUILD_TOOLS_DIR)/scripts/synth_metrics.py --top $(TOP_MODULE) --run asic --outdir $(SYNTH_OUTDIR) --logdir $(SYNTH_LOGDIR)

# Allow for custom cleanup in separate repos
EXTRA_CLEAN ?=

clean:
	rm -rf work *.vcd transcript vsim.wlf run_*.macro *.log obj_dir build.f metrics.ys $(SYNTH_LOGDIR)/metrics-*.log $(EXTRA_CLEAN)
