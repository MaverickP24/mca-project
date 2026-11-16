# ==============================================================================
# Makefile: Write-Back Cache Controller — MCA Phase I
# Toolchain: Icarus Verilog (iverilog), VVP runtime, GTKWave waveform viewer
# ==============================================================================

# Compiler & Simulator Tools
IVERILOG    := iverilog
VVP         := vvp
GTKWAVE     := gtkwave

# Flags
VFLAGS      := -g2001 -Wall -I rtl
SIM_FLAGS   := 

# Directories
RTL_DIR     := rtl
TB_DIR      := testbench
SIM_DIR     := simulation
WAVE_DIR    := $(SIM_DIR)/waveforms

# Source files
RTL_SRCS    := $(RTL_DIR)/cache_memory.v \
               $(RTL_DIR)/cache_controller.v \
               $(RTL_DIR)/main_memory.v \
               $(RTL_DIR)/top_module.v

TB_SRCS     := $(TB_DIR)/tb_cache_controller.v

# Output artifacts
SIM_BIN     := $(SIM_DIR)/cache_sim.out
VCD_FILE    := $(WAVE_DIR)/cache_simulation.vcd

.PHONY: all compile test wave clean dirs help

all: test

dirs:
	@mkdir -p $(SIM_DIR) $(WAVE_DIR)

# Compile Verilog RTL and Testbench
compile: dirs
	@echo "=========================================================="
	@echo " Compiling Write-Back Cache Controller RTL & Testbench..."
	@echo "=========================================================="
	$(IVERILOG) $(VFLAGS) -o $(SIM_BIN) $(RTL_SRCS) $(TB_SRCS)
	@echo "Compilation successful: $(SIM_BIN)"

# Run simulation testbench
test: compile
	@echo "=========================================================="
	@echo " Executing Self-Checking Simulation Testbench..."
	@echo "=========================================================="
	$(VVP) $(SIM_BIN) $(SIM_FLAGS)

# Open waveform in GTKWave
wave: $(VCD_FILE)
	@if command -v $(GTKWAVE) >/dev/null 2>&1; then \
		echo "Launching GTKWave with $(VCD_FILE)..."; \
		$(GTKWAVE) $(VCD_FILE) >/dev/null 2>&1 & \
	else \
		echo "GTKWave executable not found in PATH."; \
		echo "Waveform file exists at: $(VCD_FILE)"; \
		echo "Install GTKWave via: brew install --cask gtkwave"; \
		echo "Or view in VS Code with the 'WaveTrace' extension."; \
	fi

# Clean generated build and simulation files
clean:
	@echo "Cleaning simulation artifacts..."
	@rm -f $(SIM_BIN)
	@rm -f $(VCD_FILE)
	@echo "Clean completed."

help:
	@echo "Write-Back Cache Controller Makefile Targets:"
	@echo "  make compile  : Compile RTL and Testbench with iverilog"
	@echo "  make test     : Run simulation and print PASS/FAIL results"
	@echo "  make wave     : Open simulation waveform in GTKWave"
	@echo "  make clean    : Remove compiled binaries and waveforms"
	@echo "  make help     : Display this help message"

