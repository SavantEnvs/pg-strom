#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Known-answer tests over the arrow-tools that mayhem/build.sh built with normal flags
# (mayhem/build-test/). Each case runs a tool on a committed input and diffs its stdout (or the CSV
# dump of the file it wrote) against a committed golden file in mayhem/test/expected/.
B="$SRC/mayhem/build-test"
EXP="$SRC/mayhem/test/expected"
SA=a:int32,b:text,c:float8,d:date,e:bool,f:time,g:timestamp,h:int16,i:float2,j:uint64,k:utf8-large
SP=a:int32,b:text,c:float8,d:date,e:bool,f:time,g:timestamp,h:int16,j:uint64
for tool in arrow2csv pg2arrow tsv2arrow vcf2arrow; do
  [ -x "$B/$tool" ] || { echo "missing $B/$tool (mayhem/build.sh must build it)" >&2; emit_ctrf arrow-tools-kat 0 1; exit 1; }
done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pgstrom-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
passed=0; failed=0

# check <name>: compare $WORK/<name>.out with $EXP/<name>.out
check() {
  if [ -s "$WORK/$1.out" ] && diff -u "$EXP/$1.out" "$WORK/$1.out"; then
    echo "PASS $1"; passed=$((passed + 1))
  else
    echo "FAIL $1"; failed=$((failed + 1))
  fi
}

# Arrow writer (tsv2arrow, quoted tokens, every scalar type) -> Arrow reader (arrow2csv)
"$B/tsv2arrow" -o "$WORK/t.arrow" -S "$SA" mayhem/tsv2arrow/testsuite/rows.tsv >/dev/null 2>&1
"$B/arrow2csv" --header "$WORK/t.arrow" > "$WORK/tsv2arrow_roundtrip.out" 2>&1
check tsv2arrow_roundtrip
# Parquet writer -> Parquet reader
"$B/tsv2arrow" --parquet -o "$WORK/t.parquet" -S "$SP" mayhem/tsv2arrow_parquet/testsuite/rows.tsv >/dev/null 2>&1
"$B/arrow2csv" --header "$WORK/t.parquet" > "$WORK/tsv2arrow_parquet_roundtrip.out" 2>&1
check tsv2arrow_parquet_roundtrip
# Schema-definition parser (schema from the first line)
"$B/tsv2arrow" --schema-from-input -o "$WORK/s.arrow" mayhem/tsv2arrow_schema/testsuite/simple.txt >/dev/null 2>&1
"$B/arrow2csv" --header "$WORK/s.arrow" > "$WORK/tsv2arrow_schema.out" 2>&1
check tsv2arrow_schema
# VCF parser -> Arrow, and -> Parquet
"$B/vcf2arrow" -f -o "$WORK/v.arrow" mayhem/vcf2arrow/testsuite/sample.vcf >/dev/null 2>&1
"$B/arrow2csv" --header "$WORK/v.arrow" > "$WORK/vcf2arrow.out" 2>&1
check vcf2arrow
"$B/vcf2arrow" -f -q -o "$WORK/v.parquet" mayhem/vcf2arrow_parquet/testsuite/sample.vcf >/dev/null 2>&1
"$B/arrow2csv" --header "$WORK/v.parquet" > "$WORK/vcf2arrow_parquet.out" 2>&1
check vcf2arrow_parquet
# Committed Arrow/Parquet files: DDL + data dump, metadata dump, pg2arrow schema DDL
"$B/arrow2csv" --create-table=t mayhem/arrow2csv/testsuite/types.parquet > "$WORK/arrow2csv_create_table.out" 2>&1
check arrow2csv_create_table
"$B/arrow2csv" --meta mayhem/arrow2csv_meta/testsuite/types.arrow > "$WORK/arrow2csv_meta_arrow.out" 2>&1
check arrow2csv_meta_arrow
"$B/arrow2csv" --meta mayhem/arrow2csv_meta/testsuite/vcf.parquet > "$WORK/arrow2csv_meta_parquet.out" 2>&1
check arrow2csv_meta_parquet
"$B/pg2arrow" --schema mayhem/pg2arrow_schema/testsuite/vcf.arrow > "$WORK/pg2arrow_schema.out" 2>&1
check pg2arrow_schema

emit_ctrf arrow-tools-kat "$passed" "$failed" 0
