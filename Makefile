SAIL_SEQ_INST  = riscv.sail riscv_jalr_seq.sail
SAIL_RMEM_INST = riscv.sail riscv_jalr_rmem.sail

SAIL_SEQ_INST_SRCS  = riscv_insts_begin.sail $(SAIL_SEQ_INST) riscv_insts_end.sail
SAIL_RMEM_INST_SRCS = riscv_insts_begin.sail $(SAIL_RMEM_INST) riscv_insts_end.sail

# non-instruction sources
SAIL_OTHER_SRCS = prelude.sail riscv_types.sail riscv_sys.sail riscv_platform.sail riscv_mem.sail riscv_vmem.sail
SAIL_OTHER_RVFI_SRCS = prelude.sail rvfi_dii.sail riscv_types.sail riscv_sys.sail riscv_platform.sail riscv_mem.sail riscv_vmem.sail

SAIL_SRCS      = $(SAIL_OTHER_SRCS) $(SAIL_SEQ_INST_SRCS)  riscv_step.sail riscv_analysis.sail
SAIL_RMEM_SRCS = $(SAIL_OTHER_SRCS) $(SAIL_RMEM_INST_SRCS) riscv_step.sail riscv_analysis.sail
SAIL_RVFI_SRCS = $(SAIL_OTHER_RVFI_SRCS) $(SAIL_SEQ_INST_SRCS)  riscv_step.sail riscv_analysis.sail
SAIL_COQ_SRCS  = $(SAIL_OTHER_SRCS) $(SAIL_SEQ_INST_SRCS)  riscv_termination.sail riscv_analysis.sail

PLATFORM_OCAML_SRCS = platform.ml platform_impl.ml platform_main.ml

#Attempt to work with either sail from opam or built from repo in SAIL_DIR
ifneq ($(SAIL_DIR),)
# Use sail repo in SAIL_DIR
SAIL:=$(SAIL_DIR)/sail
export SAIL_DIR
else
# Use sail from opam package
SAIL_DIR=$(shell opam config var sail:share)
SAIL:=sail
endif
SAIL_LIB_DIR:=$(SAIL_DIR)/lib
SAIL_SRC_DIR:=$(SAIL_DIR)/src

#Coq BBV library hopefully checked out in directory above us
BBV_DIR?=../bbv

C_WARNINGS ?=
#-Wall -Wextra -Wno-unused-label -Wno-unused-parameter -Wno-unused-but-set-variable -Wno-unused-function
C_INCS = riscv_prelude.h riscv_platform_impl.h riscv_platform.h
C_SRCS = riscv_prelude.c riscv_platform_impl.c riscv_platform.c

C_FLAGS = -I $(SAIL_LIB_DIR)
C_LIBS  = -lgmp -lz

# The C simulator can be built to be linked against Spike for tandem-verification.
# This needs the C bindings to Spike from https://github.com/SRI-CSL/l3riscv
# TV_SPIKE_DIR in the environment should point to the top-level dir of the L3
# RISC-V, containing the built C bindings to Spike.
# RISCV should be defined if TV_SPIKE_DIR is.
ifneq (,$(TV_SPIKE_DIR))
C_FLAGS += -I $(TV_SPIKE_DIR)/src/cpp -DENABLE_SPIKE
C_LIBS  += -L $(TV_SPIKE_DIR) -ltv_spike -Wl,-rpath=$(TV_SPIKE_DIR)
C_LIBS  += -L $(RISCV)/lib -lfesvr -lriscv -Wl,-rpath=$(RISCV)/lib
endif

ifneq (,$(COVERAGE))
C_FLAGS += --coverage -O1
SAIL_FLAGS += -Oconstant_fold
else
C_FLAGS += -O2
endif

all: platform riscv_sim riscv_isa riscv_coq

.PHONY: all riscv_coq riscv_isa

check: $(SAIL_SRCS) main.sail Makefile
	$(SAIL) $(SAIL_FLAGS) $(SAIL_SRCS) main.sail

interpret: $(SAIL_SRCS)
	$(SAIL) -i $(SAIL_FLAGS) $(SAIL_SRCS) main.sail

cgen: $(SAIL_SRCS)
	$(SAIL) -cgen $(SAIL_FLAGS) $(SAIL_SRCS) main.sail

_sbuild/riscv.ml: $(SAIL_SRCS) Makefile main.sail
	$(SAIL) $(SAIL_FLAGS) -ocaml -ocaml-nobuild -o riscv $(SAIL_SRCS)

_sbuild/platform_main.native: _sbuild/riscv.ml _tags $(PLATFORM_OCAML_SRCS) Makefile
	cp _tags $(PLATFORM_OCAML_SRCS) _sbuild
	cd _sbuild && ocamlbuild -use-ocamlfind platform_main.native

_sbuild/coverage.native: _sbuild/riscv.ml _tags.bisect $(PLATFORM_OCAML_SRCS) Makefile
	cp $(PLATFORM_OCAML_SRCS) _sbuild
	cp _tags.bisect _sbuild/_tags
	cd _sbuild && ocamlbuild -use-ocamlfind platform_main.native && cp -L platform_main.native coverage.native

platform: _sbuild/platform_main.native
	rm -f $@ && ln -s $^ $@

coverage: _sbuild/coverage.native
	rm -f platform && ln -s $^ platform # since the test scripts runs this file
	rm -rf bisect*.out bisect coverage
	../test/riscv/run_tests.sh # this will generate bisect*.out files in this directory
	mkdir bisect && mv bisect*.out bisect/
	mkdir coverage && bisect-ppx-report -html coverage/ -I _sbuild/ bisect/bisect*.out

gcovr:
	gcovr -r . --html --html-detail -o index.html

riscv.c: $(SAIL_SRCS) main.sail Makefile
	$(SAIL) $(SAIL_FLAGS) -O -memo_z3 -c -c_include riscv_prelude.h -c_include riscv_platform.h $(SAIL_SRCS) main.sail 1> $@

riscv_c: riscv.c $(C_INCS) $(C_SRCS) Makefile
	gcc $(C_WARNINGS) $(C_FLAGS) riscv.c $(C_SRCS) $(SAIL_LIB_DIR)/*.c -lgmp -lz -I $(SAIL_LIB_DIR) -o riscv_c

riscv_model.c: $(SAIL_SRCS) main.sail Makefile
	$(SAIL) $(SAIL_FLAGS) -O -memo_z3 -c -c_include riscv_prelude.h -c_include riscv_platform.h -c_no_main $(SAIL_SRCS) main.sail 1> $@

riscv_sim: riscv_model.c riscv_sim.c $(C_INCS) $(C_SRCS) $(CPP_SRCS) Makefile
	gcc -g $(C_WARNINGS) $(C_FLAGS) riscv_model.c riscv_sim.c $(C_SRCS) $(SAIL_LIB_DIR)/*.c $(C_LIBS) -o $@

riscv_rvfi_model.c: $(SAIL_RVFI_SRCS) main_rvfi.sail Makefile
	$(SAIL) $(SAIL_FLAGS) -O -memo_z3 -c -c_include riscv_prelude.h -c_include riscv_platform.h -c_no_main $(SAIL_RVFI_SRCS) main_rvfi.sail | sed '/^[[:space:]]*$$/d' > $@

riscv_rvfi: riscv_rvfi_model.c riscv_sim.c $(C_INCS) $(C_SRCS) $(CPP_SRCS) Makefile
	gcc -g $(C_WARNINGS) $(C_FLAGS) riscv_rvfi_model.c -DRVFI_DII riscv_sim.c $(C_SRCS) $(SAIL_LIB_DIR)/*.c $(C_LIBS) -o $@

latex: $(SAIL_SRCS) Makefile
	$(SAIL) -latex -latex_prefix sail -o sail_ltx $(SAIL_SRCS)

tracecmp: tracecmp.ml
	ocamlfind ocamlopt -annot -linkpkg -package unix $^ -o $@

riscv_duopod_ocaml: prelude.sail riscv_duopod.sail
	$(SAIL) $(SAIL_FLAGS) -ocaml -o $@ $^

riscv_duopod.lem: prelude.sail riscv_duopod.sail
	$(SAIL) $(SAIL_FLAGS) -lem -lem_mwords -lem_lib Riscv_extras -o riscv_duopod $^
Riscv_duopod.thy: riscv_duopod.lem riscv_extras.lem
	lem -isa -outdir . -lib Sail=$(SAIL_SRC_DIR)/lem_interp -lib Sail=$(SAIL_SRC_DIR)/gen_lib \
		riscv_extras.lem \
		riscv_duopod_types.lem \
		riscv_duopod.lem

riscv_duopod: riscv_duopod_ocaml Riscv_duopod.thy

riscv_isa: Riscv.thy

Riscv.thy: riscv.lem riscv_extras.lem Makefile
	lem -isa -outdir . -lib Sail=$(SAIL_SRC_DIR)/lem_interp -lib Sail=$(SAIL_SRC_DIR)/gen_lib \
		riscv_extras.lem \
		riscv_types.lem \
		riscv.lem
	sed -i 's/datatype ast/datatype (plugins only: size) ast/' Riscv_types.thy

riscv.lem: $(SAIL_SRCS) Makefile
	$(SAIL) $(SAIL_FLAGS) -lem -o riscv -lem_mwords -lem_lib Riscv_extras $(SAIL_SRCS)

riscv_sequential.lem: $(SAIL_SRCS) Makefile
	$(SAIL_DIR)/sail -lem -lem_sequential -o riscv_sequential -lem_mwords -lem_lib Riscv_extras_sequential $(SAIL_SRCS)

riscvScript.sml : riscv.lem riscv_extras.lem
	lem -hol -outdir . -lib $(SAIL_LIB_DIR)/hol -i $(SAIL_LIB_DIR)/hol/sail2_prompt_monad.lem -i $(SAIL_LIB_DIR)/hol/sail2_prompt.lem \
	    -lib $(SAIL_DIR)/src/lem_interp -lib $(SAIL_DIR)/src/gen_lib \
		riscv_extras.lem \
		riscv_types.lem \
		riscv.lem

riscvTheory.uo riscvTheory.ui: riscvScript.sml
	Holmake riscvTheory.uo

COQ_LIBS = -R $(BBV_DIR)/theories bbv -R $(SAIL_LIB_DIR)/coq Sail

riscv_coq: riscv.v riscv_types.v

riscv.v riscv_types.v: $(SAIL_COQ_SRCS) Makefile
	$(SAIL) $(SAIL_FLAGS) -dcoq_undef_axioms -coq -o riscv -coq_lib riscv_extras $(SAIL_COQ_SRCS)
riscv_duopod.v riscv_duopod_types.v:  prelude.sail riscv_duopod.sail
	$(SAIL) $(SAIL_FLAGS) -dcoq_undef_axioms -coq -o riscv_duopod -coq_lib riscv_extras $^
%.vo: %.v
	coqc $(COQ_LIBS) $<
riscv.vo: riscv_types.vo riscv_extras.vo
riscv_duopod.vo: riscv_duopod_types.vo riscv_extras.vo

# we exclude prelude.sail here, most code there should move to sail lib
#LOC_FILES:=$(SAIL_SRCS) main.sail
#include $(SAIL_DIR)/etc/loc.mk

clean:
	-rm -rf riscv _sbuild
	-rm -f riscv.lem riscv_types.lem
	-rm -f Riscv.thy Riscv_types.thy \
		Riscv_extras.thy
	-rm -f Riscv_duopod.thy Riscv_duopod_types.thy riscv_duopod.lem riscv_duopod_types.lem
	-rm -f riscvScript.sml riscv_typesScript.sml riscv_extrasScript.sml
	-rm -f platform_main.native platform coverage.native
	-rm -f riscv.vo riscv_types.vo riscv_extras.vo riscv.v riscv_types.v
	-rm -f riscv_duopod.vo riscv_duopod_types.vo riscv_duopod.v riscv_duopod_types.v
	-rm -f riscv.c riscv_model.c riscv_sim
	-rm -f riscv_rvfi_model.c riscv_rvfi
	-rm -f *.gcno *.gcda
	-Holmake cleanAll
	ocamlbuild -clean
