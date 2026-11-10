#!/usr/bin/env bash
#
# Build and debug a small program with the installed GDB, then check that
# every expected capability actually worked.
#
# Passing this script is the definition of a working build: it exercises
# Mach-O loading, breakpoints, stepping, backtraces, register access and the
# ARM64 hardware watchpoint registers on a real inferior.

set -eu -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

PROG=$(basename -- "$0")
GDB_PATH=
KEEP=0
VERBOSE=0
TIMEOUT=180
PASSED=0
FAILED=0
WORKDIR=
OUTPUT=

usage()
{
	cat <<EOF
Usage: ${PROG} [options]

Compile tests/probe.c, debug it with the installed GDB and verify that the
AArch64 Darwin backend behaves correctly.  The checks cover:

  * Mach-O object file recognition
  * source breakpoints
  * next/step over source lines
  * backtraces with symbols and line numbers
  * pc and sp register access
  * hardware watchpoints with old/new values
  * running the inferior to completion

Options:
  --gdb PATH      GDB binary to test (default: <prefix>/bin/gdb)
  --prefix DIR    Installation prefix (default: ${GAD_PREFIX})
  --timeout SECS  Give up after this many seconds (default: ${TIMEOUT})
  --verbose       Show the complete GDB output
  --keep          Keep the temporary directory with the build artefacts
  -h, --help      Show this help

Exit status is 0 only when every check passes.

Examples:
  ./scripts/verify.sh
  ./scripts/verify.sh --gdb ./dist/bin/gdb --verbose
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--gdb)
			need_value "$1" "$#"
			GDB_PATH=$2
			shift 2
			;;
		--prefix)
			need_value "$1" "$#"
			GAD_PREFIX=$2
			shift 2
			;;
		--timeout)
			need_value "$1" "$#"
			TIMEOUT=$2
			shift 2
			;;
		--verbose)
			VERBOSE=1
			shift
			;;
		--keep)
			KEEP=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $1 (try --help)"
			;;
	esac
done

cleanup()
{
	if [ -n "${WORKDIR}" ] && [ -d "${WORKDIR}" ]; then
		if [ "${KEEP}" -eq 1 ]; then
			printf '\nkept: %s\n' "${WORKDIR}" >&2
		else
			rm -rf -- "${WORKDIR}"
		fi
	fi
}
trap cleanup EXIT

check()
{
	local label=$1 pattern=$2
	if printf '%s\n' "${OUTPUT}" | grep -E -- "${pattern}" >/dev/null; then
		PASSED=$((PASSED + 1))
		printf '  %s ok %s %s\n' "${C_GREEN}" "${C_RESET}" "${label}"
	else
		FAILED=$((FAILED + 1))
		printf '  %sfail%s %s\n' "${C_RED}" "${C_RESET}" "${label}"
		printf '        expected output matching: %s\n' "${pattern}"
	fi
}

# Run a command with a wall-clock limit, writing its combined output to a
# file.  macOS has no timeout(1), and a command substitution around GDB can
# block on file descriptors inherited by the inferior, so the output goes to
# a file and the watchdog kills the process from a sibling shell.
run_with_timeout()
{
	local output=$1
	shift
	local pid watchdog status=0

	"$@" >"${output}" 2>&1 &
	pid=$!
	(
		sleep "${TIMEOUT}"
		if kill -0 "${pid}" 2>/dev/null; then
			kill -TERM "${pid}" 2>/dev/null || true
			sleep 2
			kill -KILL "${pid}" 2>/dev/null || true
		fi
	) &
	watchdog=$!

	wait "${pid}" || status=$?
	kill "${watchdog}" 2>/dev/null || true
	wait "${watchdog}" 2>/dev/null || true
	return "${status}"
}

require_macos
require_arm64

if [ -z "${GDB_PATH}" ]; then
	GDB_PATH="${GAD_PREFIX}/bin/gdb"
fi
GDB_PATH=$(abspath "${GDB_PATH}") || die "cannot resolve ${GDB_PATH}"
[ -x "${GDB_PATH}" ] || die "GDB not found or not executable: ${GDB_PATH}"

step "checking the GDB signature"
"${SCRIPT_DIR}/sign.sh" --check --gdb "${GDB_PATH}" ||
	die "GDB is not signed for debugging; run ./scripts/sign.sh"

VERSION=$("${GDB_PATH}" --version 2>/dev/null | head -n 1)
step "testing ${VERSION}"

PREFIX_DIR=$(cd -- "$(dirname -- "${GDB_PATH}")/.." && pwd -P)
DATA_DIR="${PREFIX_DIR}/share/gdb"
if [ ! -d "${DATA_DIR}" ] && [ "${GDB_PATH}" = "${GAD_PREFIX}/bin/gdb" ]; then
	warn "data directory not found at ${DATA_DIR}; run ./build.sh to install it"
fi

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/gdb-aarch64-darwin-verify.XXXXXX")
PROBE="${WORKDIR}/probe"

step "compiling tests/probe.c"
/usr/bin/cc -g -O0 -fno-omit-frame-pointer -o "${PROBE}" "${GAD_ROOT}/tests/probe.c" ||
	die "cannot compile the test program"

# Python scripting is optional; when the build enabled it, make sure it
# starts, since a broken interpreter shows up as a startup failure.
if "${GDB_PATH}" --batch -nx -q -ex "show configuration" 2>/dev/null |
	grep -q -- "--with-python="; then
	OUTPUT=$("${GDB_PATH}" --batch -nx -q -ex "python print('python-ok')" 2>&1 || true)
	check "python scripting starts" "python-ok"
else
	note "python scripting was not enabled in this build"
fi

printf '\n%sRunning the smoke test%s\n' "${C_BOLD}" "${C_RESET}"

OUTPUT_FILE="${WORKDIR}/gdb-output.txt"
STATUS=0
run_with_timeout "${OUTPUT_FILE}" \
	"${GDB_PATH}" --batch -nx -q \
	-x "${GAD_ROOT}/tests/smoke.gdb" \
	--args "${PROBE}" || STATUS=$?

OUTPUT=$(cat "${OUTPUT_FILE}")

if [ "${VERBOSE}" -eq 1 ]; then
	printf '\n%s--- GDB output ---%s\n%s\n%s--- end ---%s\n\n' \
		"${C_DIM}" "${C_RESET}" "${OUTPUT}" "${C_DIM}" "${C_RESET}"
fi

check "GDB recognised the Mach-O ARM64 executable" 'file type mach-o-arm64'
check "breakpoint was placed in add()" 'Breakpoint 1 at 0x[0-9a-f]+: file .*probe\.c, line [0-9]+'
check "inferior stopped at the breakpoint" 'Breakpoint 1, add \(a=0, b=0\)'
check "backtrace shows add()" '#0[[:space:]]+add \(a=0, b=0\)'
check "backtrace shows main()" '#1[[:space:]]+0x[0-9a-f]+ in main \(\)'
check "pc register can be read" '^pc[[:space:]]+0x[0-9a-f]+'
check "sp register can be read" '^sp[[:space:]]+0x[0-9a-f]+'
check "counter is 1 after the first call" '\$[0-9]+ = 1$'
check "hardware watchpoint was installed" 'Hardware watchpoint 2: counter'
check "watchpoint reported the old value" 'Old value = 1'
check "watchpoint reported the new value" 'New value = 2'
check "counter is 2 at the second call" '\$[0-9]+ = 2$'
check "inferior produced the expected output" 'sum=10 counter=5'
check "inferior exited normally" '\[Inferior 1 .* exited normally\]'

if [ "${STATUS}" -ne 0 ]; then
	FAILED=$((FAILED + 1))
	printf '  %sfail%s GDB exited with status %s\n' "${C_RED}" "${C_RESET}" "${STATUS}"
	if [ "${STATUS}" -eq 142 ] || [ "${STATUS}" -eq 137 ]; then
		printf '        GDB did not finish within %s seconds; the inferior probably blocked in taskgated\n' "${TIMEOUT}"
	fi
else
	PASSED=$((PASSED + 1))
	printf '  %s ok %s GDB exited cleanly\n' "${C_GREEN}" "${C_RESET}"
fi

# Second phase: a library that is loaded after the first stop.  This covers
# the dyld notifier and pending breakpoint resolution, which the single
# binary test cannot reach.
printf '\n%sRunning the shared library test%s\n' "${C_BOLD}" "${C_RESET}"

LIBDIR="${WORKDIR}/lib"
mkdir -p "${LIBDIR}"
/usr/bin/cc -g -dynamiclib "${GAD_ROOT}/tests/library.c" -o "${LIBDIR}/libsample.dylib" ||
	die "cannot build the test library"
/usr/bin/cc -g -O0 "${GAD_ROOT}/tests/uses-library.c" -o "${LIBDIR}/uses-library" ||
	die "cannot build the library test program"

LIB_STATUS=0
(
	cd -- "${LIBDIR}"
	run_with_timeout "${WORKDIR}/library-output.txt" \
		"${GDB_PATH}" --batch -nx -q \
		-x "${GAD_ROOT}/tests/smoke-library.gdb" \
		--args "${LIBDIR}/uses-library"
) || LIB_STATUS=$?

OUTPUT=$(cat "${WORKDIR}/library-output.txt")
if [ "${VERBOSE}" -eq 1 ]; then
	printf '\n%s--- GDB output (library test) ---%s\n%s\n%s--- end ---%s\n\n' \
		"${C_DIM}" "${C_RESET}" "${OUTPUT}" "${C_DIM}" "${C_RESET}"
fi

check "breakpoint in the not-yet-loaded library" 'Breakpoint 2 \(library_add\) pending'
check "stopped inside the loaded library" 'Breakpoint 2, library_add \(a=2, b=3\)'
check "library frame in backtrace" '#0[[:space:]]+library_add \(a=2, b=3\)'
check "caller frame in backtrace" '#1[[:space:]]+0x[0-9a-f]+ in main \(\)'
check "library arguments" '\$[0-9]+ = 3$'
check "library program completed" 'result=5'
check "library run exited normally" '\[Inferior 1 .* exited normally\]'
if [ "${LIB_STATUS}" -ne 0 ]; then
	FAILED=$((FAILED + 1))
	printf '  %sfail%s shared library test exited with status %s\n' \
		"${C_RED}" "${C_RESET}" "${LIB_STATUS}"
else
	PASSED=$((PASSED + 1))
	printf '  %s ok %s shared library test exited cleanly\n' "${C_GREEN}" "${C_RESET}"
fi

printf '\n'
if [ "${FAILED}" -gt 0 ]; then
	printf '%s--- last lines of GDB output ---%s\n' "${C_DIM}" "${C_RESET}"
	printf '%s\n' "${OUTPUT}" | tail -n 40
	KEEP=1
	error "${FAILED} check(s) failed, ${PASSED} passed"
	exit 1
fi

ok "all ${PASSED} checks passed"
