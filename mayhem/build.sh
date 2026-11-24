#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# pg-strom's standalone arrow-tools (arrow-tools/Makefile): arrow2csv = arrow2csv.cpp + arrow_meta.cpp,
# pg2arrow = pg2arrow.cpp + arrow_meta.cpp, tsv2arrow = tsv2arrow.cpp, vcf2arrow = vcf2arrow.cpp.
# The compile/link lines below are the Makefile's own (same CPPFLAGS/defines, same pkg-config libs);
# they are spelled out because the Makefile hard-codes CFLAGS, writes objects into the source dir and
# needs pg_config (a PostgreSQL server dev install) only to derive the version string.
# The PostgreSQL extension under src/ (CUDA + a live server) is not built.
AT="$SRC/arrow-tools"
PKG_CFLAGS="$(pkg-config --cflags parquet)"
PKG_LIBS="$(pkg-config --libs parquet)"
TOOL_CPPFLAGS="-std=c++20 -I$AT -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -DPGSTROM_VERSION=\"6.2.0\"
  -DHAS_LIBARROW=1 -DHAS_PARQUET=1 $PKG_CFLAGS -I$(pkg-config --variable=includedir libpq) -Wno-sign-compare"

# build_tools <outdir> <compile flags> <link flags>
build_tools() {
  local out="$1" cflags="$2" ldflags="$3" pids=() f
  mkdir -p "$out"
  for f in arrow2csv arrow_meta pg2arrow vcf2arrow; do
    $CXX $TOOL_CPPFLAGS $cflags -c "$AT/$f.cpp" -o "$out/$f.o" & pids+=($!)
  done
  # tsv2arrow's process_one_input_file() always reads stdin, so the fuzz/test driver
  # (mayhem/tsv2arrow_input.cpp) wraps its main(): rename it, the wrapper feeds the input file.
  $CXX $TOOL_CPPFLAGS $cflags -Dmain=tsv2arrow_main -c "$AT/tsv2arrow.cpp" -o "$out/tsv2arrow.o" & pids+=($!)
  $CXX $TOOL_CPPFLAGS $cflags -c "$SRC/mayhem/tsv2arrow_input.cpp" -o "$out/tsv2arrow_input.o" & pids+=($!)
  for f in "${pids[@]}"; do wait "$f"; done
  $CXX $cflags "$out/arrow2csv.o" "$out/arrow_meta.o" $ldflags $PKG_LIBS -o "$out/arrow2csv"
  $CXX $cflags "$out/pg2arrow.o" "$out/arrow_meta.o" $ldflags $PKG_LIBS -lpq -o "$out/pg2arrow"
  $CXX $cflags "$out/vcf2arrow.o" $ldflags $PKG_LIBS -o "$out/vcf2arrow"
  $CXX $cflags "$out/tsv2arrow_input.o" "$out/tsv2arrow.o" $ldflags $PKG_LIBS -o "$out/tsv2arrow"
}

# 1+2) Fuzz build: the tools themselves are the file-input targets, so the WHOLE tool (not a harness
#      TU) carries ASan+UBSan (halting), SanCov edges (-fsanitize=fuzzer-no-link, unconditional) and
#      DWARF-3. LeakSanitizer is turned off at build time by mayhem/lsan_off.cc.
FUZZ_FLAGS="-O1 $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
FUZZ_OUT="$SRC/mayhem/build-fuzz"
mkdir -p "$FUZZ_OUT"
$CXX $FUZZ_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_OUT/lsan_off.o"
build_tools "$FUZZ_OUT" "$FUZZ_FLAGS" "$FUZZ_OUT/lsan_off.o"

# 3) Oracle build with the Makefile's normal flags (-O2 -g), no sanitizers; mayhem/test.sh runs it.
build_tools "$SRC/mayhem/build-test" "-O2 -g -fPIC $COVERAGE_FLAGS" "$COVERAGE_FLAGS"

ls -l "$FUZZ_OUT"/{arrow2csv,pg2arrow,vcf2arrow,tsv2arrow} "$SRC"/mayhem/build-test/{arrow2csv,pg2arrow,vcf2arrow,tsv2arrow}
