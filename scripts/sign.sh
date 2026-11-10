#!/usr/bin/env bash
#
# Sign the GDB binary (and optionally an inferior) so that macOS lets it
# control other processes.

set -eu -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

PROG=$(basename -- "$0")
GDB_PATH=
IDENTITY=
CHECK_ONLY=0
VERIFY=1
LIST=0
TARGETS=()

usage()
{
	cat <<EOF
Usage: ${PROG} [options] [inferior ...]

macOS only hands out a task port to a debugger that is signed with an
identity it trusts and carries the com.apple.security.cs.debugger
entitlement.  This script applies that signature to the GDB produced by
./build.sh.

A GDB that is only ad hoc signed starts, loads symbols and shows the
source, but blocks in taskgated the moment an inferior is started.  That
is why an identity is required and why the signature is verified here.

Options:
  --gdb PATH             GDB binary to sign (default: <prefix>/bin/gdb)
  --prefix DIR           Installation prefix (default: ${GAD_PREFIX})
  --identity NAME        Signing identity; default is the first
                         "Apple Development" identity
  --target FILE          Also sign an inferior with get-task-allow; may be
                         repeated.  Only needed for programs GDB attaches to,
                         not for programs it launches itself.
  --check                Do not sign; verify the existing signature and exit
  --list-identities      Print the usable codesigning identities and exit
  --no-verify            Skip the codesign verification after signing
  --dry-run              Print the commands that would run
  -h, --help             Show this help

Environment:
  CODESIGN_IDENTITY, GAD_PREFIX, GAD_DRY_RUN, GAD_VERBOSE

Examples:
  ./scripts/sign.sh
  ./scripts/sign.sh --identity "Apple Development: Name (TEAMID)"
  ./scripts/sign.sh --check
  ./scripts/sign.sh --target ./a.out
  ./scripts/sign.sh --list-identities

Exit status is 0 when the binary is correctly signed and entitled, 1
otherwise.
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
		--identity)
			need_value "$1" "$#"
			IDENTITY=$2
			shift 2
			;;
		--target)
			need_value "$1" "$#"
			TARGETS[${#TARGETS[@]}]=$2
			shift 2
			;;
		--check)
			CHECK_ONLY=1
			shift
			;;
		--list-identities)
			LIST=1
			shift
			;;
		--no-verify)
			VERIFY=0
			shift
			;;
		--dry-run)
			GAD_DRY_RUN=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		--)
			shift
			while [ "$#" -gt 0 ]; do
				TARGETS[${#TARGETS[@]}]=$1
				shift
			done
			;;
		-*)
			die "unknown argument: $1 (try --help)"
			;;
		*)
			TARGETS[${#TARGETS[@]}]=$1
			shift
			;;
	esac
done

identity_help()
{
	cat >&2 <<'EOF'
Create a signing identity with Xcode > Settings > Accounts > Manage
Certificates > Apple Development, or with:

  security create-keychain ...
  # a full walkthrough is in docs/SIGNING.md

Then confirm that it is visible to codesign:

  security find-identity -v -p codesigning
EOF
}

list_identities()
{
	local identities
	identities=$(codesign_identities)
	if [ -z "${identities}" ]; then
		printf 'No codesigning identities found.\n'
		return 1
	fi
	printf 'Codesigning identities:\n'
	printf '%s\n' "${identities}" | sed 's/^/  /'
}

has_entitlement()
{
	local binary=$1 key=$2 output
	# Capture first: codesign keeps writing after grep -q finds a match and
	# the resulting SIGPIPE would make the pipeline fail under pipefail.
	output=$(codesign -d --entitlements - "${binary}" 2>&1 || true)
	printf '%s\n' "${output}" | grep -Fq -- "${key}"
}

describe_signature()
{
	local binary=$1
	codesign -dvvv "${binary}" 2>&1 |
		sed -n -E '/^(Executable|Identifier|Format|Authority|TeamIdentifier|Signature|flags)=/p' |
		sed 's/^/  /'
}

sign_binary()
{
	local binary=$1 entitlements=$2
	run codesign --force --options runtime --timestamp=none \
		--entitlements "${entitlements}" \
		--sign "${IDENTITY}" "${binary}"
}

verify_binary()
{
	local binary=$1 key=$2 expected=$3

	codesign --verify --strict --verbose=2 "${binary}" >/dev/null 2>&1 ||
		die "codesign verification failed for ${binary}"

	if ! has_entitlement "${binary}" "${key}"; then
		die "${binary} is signed but lacks the ${key} entitlement"
	fi

	if [ "${expected}" -eq 1 ]; then
		local info
		info=$(codesign -dvvv "${binary}" 2>&1 || true)
		if printf '%s\n' "${info}" | grep -q '^Signature=adhoc'; then
			die "${binary} is only ad hoc signed; taskgated will refuse to debug"
		fi
	fi
}

require_macos

if [ "${LIST}" -eq 1 ]; then
	list_identities
	exit 0
fi

require_cmd codesign "install the Xcode command line tools"
require_cmd security "install the Xcode command line tools"

if [ -z "${GDB_PATH}" ]; then
	GDB_PATH="${GAD_PREFIX}/bin/gdb"
fi
GDB_PATH=$(abspath "${GDB_PATH}") || die "cannot resolve ${GDB_PATH}"
[ -f "${GDB_PATH}" ] || die "GDB not found at ${GDB_PATH}; run ./build.sh first"
[ -x "${GDB_PATH}" ] || die "GDB is not executable: ${GDB_PATH}"

GDB_ENTITLEMENTS="${GAD_ROOT}/entitlements/gdb.entitlements"
INFERIOR_ENTITLEMENTS="${GAD_ROOT}/entitlements/inferior.entitlements"
[ -r "${GDB_ENTITLEMENTS}" ] || die "missing entitlement file: ${GDB_ENTITLEMENTS}"
[ -r "${INFERIOR_ENTITLEMENTS}" ] || die "missing entitlement file: ${INFERIOR_ENTITLEMENTS}"

if [ "${CHECK_ONLY}" -eq 1 ]; then
	step "checking ${GDB_PATH}"
	verify_binary "${GDB_PATH}" "com.apple.security.cs.debugger" 1
	describe_signature "${GDB_PATH}"
	ok "signature and entitlement are valid"
	exit 0
fi

if [ -z "${IDENTITY}" ]; then
	IDENTITY=${CODESIGN_IDENTITY:-}
fi
if [ -z "${IDENTITY}" ]; then
	IDENTITY=$(select_signing_identity "") || {
		error "no usable codesigning identity found"
		identity_help
		exit 1
	}
fi

available_identities=$(codesign_identities)
if ! printf '%s\n' "${available_identities}" | grep -Fxq -- "${IDENTITY}"; then
	error "codesigning identity not found: ${IDENTITY}"
	printf '%s\n' "${available_identities}" | sed 's/^/  /' >&2
	identity_help
	exit 1
fi

step "signing GDB"
info "  identity: ${IDENTITY}"
info "  binary:   ${GDB_PATH}"
sign_binary "${GDB_PATH}" "${GDB_ENTITLEMENTS}"

if [ "${VERIFY}" -eq 1 ] && [ "${GAD_DRY_RUN}" -eq 0 ]; then
	step "verifying signature"
	verify_binary "${GDB_PATH}" "com.apple.security.cs.debugger" 1
	describe_signature "${GDB_PATH}"
fi

if [ "${#TARGETS[@]}" -gt 0 ]; then
	for target in "${TARGETS[@]}"; do
		target=$(abspath "${target}") || die "cannot resolve ${target}"
		[ -f "${target}" ] || die "inferior not found: ${target}"
		[ "${target}" != "${GDB_PATH}" ] || die "refusing to sign GDB as an inferior"
		step "signing inferior ${target}"
		sign_binary "${target}" "${INFERIOR_ENTITLEMENTS}"
		if [ "${VERIFY}" -eq 1 ] && [ "${GAD_DRY_RUN}" -eq 0 ]; then
			verify_binary "${target}" "com.apple.security.get-task-allow" 0
		fi
	done
fi

printf '\n'
ok "GDB is ready to debug"
printf '  %s\n' "${GDB_PATH}"
