#!/usr/bin/env bash
#
# Fetch the pinned upstream binutils-gdb revision and apply the AArch64
# Darwin patch series.
#
# Diagnostics go to stderr; the absolute path of the patched source tree is
# printed on stdout so callers can capture it:
#
#   source_dir=$(./scripts/bootstrap.sh)

set -eu -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

PROG=$(basename -- "$0")
SOURCE_OPT=
REV=${UPSTREAM_REV}
REFRESH=0
OFFLINE=0
CLEAN=0
LATEST=0
THREE_WAY=0

usage()
{
	cat <<EOF
Usage: ${PROG} [options]

Prepare a binutils-gdb source tree that contains the AArch64 Darwin
backend.  The upstream revision is pinned to:

  ${UPSTREAM_REV}

and the six patches in patches/series are applied on top of it.

The first run clones the upstream repository into .cache/binutils-gdb.
That checkout is large (about 600 MB); later runs reuse it and only reset
the working tree, so this cost is paid once.

Options:
  --source DIR   Use an existing source tree instead of the cache.  The
                 patches are applied in place; a tree that already contains
                 the backend is left untouched.
  --rev REV      Upstream revision to check out (default: pinned revision)
  --cache DIR    Directory for the cached clone (default: ${GAD_CACHE_DIR})
  --latest       Build the current upstream master instead of the pinned
                 revision.  Patches are applied with a three-way merge so
                 that ordinary upstream drift is absorbed automatically.
  --refresh      Fetch new upstream objects before checking out
  --offline      Do not touch the network; fail if the revision is not cached
  --clean        Remove the cached checkout before preparing the tree
  --dry-run      Print the commands that would run
  -h, --help     Show this help

Environment:
  GAD_UPSTREAM_URL, GAD_CACHE_DIR, GAD_SOURCE_DIR, GAD_VERBOSE

Examples:
  ./scripts/bootstrap.sh
  ./scripts/bootstrap.sh --refresh
  ./scripts/bootstrap.sh --source /path/to/binutils-gdb
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--source)
			need_value "$1" "$#"
			SOURCE_OPT=$2
			shift 2
			;;
		--rev)
			need_value "$1" "$#"
			REV=$2
			shift 2
			;;
		--cache)
			need_value "$1" "$#"
			GAD_CACHE_DIR=$2
			GAD_SOURCE_DIR="${GAD_CACHE_DIR}/binutils-gdb"
			shift 2
			;;
		--latest)
			LATEST=1
			THREE_WAY=1
			shift
			;;
		--refresh)
			REFRESH=1
			shift
			;;
		--offline)
			OFFLINE=1
			shift
			;;
		--clean)
			CLEAN=1
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
		*)
			die "unknown argument: $1 (try --help)"
			;;
	esac
done

[ "$#" -eq 0 ] || die "unexpected argument: $1"

if [ "${LATEST}" -eq 1 ] && [ -n "${SOURCE_OPT}" ]; then
	die "--latest and --source cannot be combined"
fi

series_digest()
{
	shasum -a 256 "${GAD_ROOT}"/patches/*.patch "${GAD_ROOT}/patches/series" |
		shasum -a 256 |
		awk '{ print $1 }'
}

stamp_is_current()
{
	local dir=$1 stamp digest
	stamp="${dir}/.gdb-aarch64-darwin"
	[ -f "${stamp}" ] || return 1
	[ -f "${dir}/gdb/aarch64-darwin-nat.c" ] || return 1
	digest=$(series_digest)
	grep -Fxq "revision ${REV}" "${stamp}" || return 1
	grep -Fxq "series ${digest}" "${stamp}" || return 1
	return 0
}

write_stamp()
{
	local dir=$1 digest
	digest=$(series_digest)
	{
		printf 'revision %s\n' "${REV}"
		printf 'series %s\n' "${digest}"
	} >"${dir}/.gdb-aarch64-darwin"
}

# apply_series DIR: apply every patch in patches/series to DIR.  Returns
# non-zero on failure and leaves the decision about cleaning up to the caller.
apply_series()
{
	local dir=$1 name patch
	local use_git=0 conflicts

	if git -C "${dir}" rev-parse --git-dir >/dev/null 2>&1; then
		use_git=1
	fi

	while IFS= read -r name; do
		[ -n "${name}" ] || continue
		patch="${GAD_ROOT}/patches/${name}"
		[ -f "${patch}" ] || die "patch listed in series is missing: ${patch}"
		step "applying ${name}"
		if [ "${use_git}" -eq 1 ]; then
			if [ "${THREE_WAY}" -eq 1 ]; then
				if ! git -C "${dir}" apply --3way --whitespace=nowarn "${patch}"; then
					error "cannot apply ${name}: the three-way merge failed"
					conflicts=$(git -C "${dir}" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
					[ -n "${conflicts}" ] && info "conflicted paths: ${conflicts}"
					return 1
				fi
			else
				git -C "${dir}" apply --check "${patch}" || {
					error "${name} does not apply; the tree is probably not at ${REV}"
					return 1
				}
				run git -C "${dir}" apply --whitespace=nowarn "${patch}" || return 1
			fi
		else
			(
				cd -- "${dir}"
				run patch -p1 --batch --forward --silent <"${patch}"
			) || {
				error "${name} does not apply; the tree is probably not at ${REV}"
				return 1
			}
		fi
	done <"${GAD_ROOT}/patches/series"
	return 0
}

verify_source_tree()
{
	local dir=$1
	[ -d "${dir}" ] || die "source directory does not exist: ${dir}"
	[ -f "${dir}/configure" ] || die "not a binutils-gdb source tree (no configure): ${dir}"
	[ -d "${dir}/gdb" ] || die "not a binutils-gdb source tree (no gdb directory): ${dir}"
}

prepare_external_source()
{
	local dir=$1

	dir=$(abspath "${dir}") || die "cannot resolve source directory: ${dir}"
	verify_source_tree "${dir}"

	if stamp_is_current "${dir}"; then
		ok "source tree already contains the backend"
		printf '%s\n' "${dir}"
		return 0
	fi

	if [ -f "${dir}/gdb/aarch64-darwin-nat.c" ]; then
		warn "source tree contains the backend but no matching stamp; leaving it untouched"
		printf '%s\n' "${dir}"
		return 0
	fi

	step "applying the patch series to ${dir}"
	apply_series "${dir}" || die "the series does not apply to ${dir}; reset that tree before retrying"
	if [ "${GAD_DRY_RUN}" -eq 1 ]; then
		printf '%s\n' "${dir}"
		return 0
	fi
	write_stamp "${dir}"
	ok "source tree prepared"
	printf '%s\n' "${dir}"
}

prepare_cached_source()
{
	local clone=${GAD_CACHE_DIR}/binutils-gdb name

	if [ "${CLEAN}" -eq 1 ]; then
		step "removing cached checkout ${clone}"
		run rm -rf -- "${clone}"
	fi

	if [ "${GAD_DRY_RUN}" -eq 1 ]; then
		print_command mkdir -p -- "${GAD_CACHE_DIR}"
		print_command git clone --progress "${UPSTREAM_URL}" "${clone}"
		if [ "${LATEST}" -eq 1 ]; then
			print_command git -C "${clone}" fetch --prune --quiet origin master
			print_command git -C "${clone}" rev-parse origin/master
		fi
		print_command git -C "${clone}" checkout --detach --force --quiet "${REV}"
		while IFS= read -r name; do
			[ -n "${name}" ] || continue
			print_command git -C "${clone}" apply "${GAD_ROOT}/patches/${name}"
		done <"${GAD_ROOT}/patches/series"
		printf '%s\n' "${clone}"
		return 0
	fi

	if [ ! -d "${clone}" ]; then
		[ "${OFFLINE}" -eq 0 ] || die "no cached checkout at ${clone} and --offline was given"
		info "cloning ${UPSTREAM_URL}"
		info "this is a one-time download of roughly 600 MB"
		mkdir -p -- "${GAD_CACHE_DIR}"
		git clone --progress "${UPSTREAM_URL}" "${clone}" ||
			die "git clone failed; check the network or pass --source DIR"
	fi

	git -C "${clone}" rev-parse --git-dir >/dev/null 2>&1 ||
		die "${clone} exists but is not a git checkout"

	if [ "${LATEST}" -eq 1 ]; then
		[ "${OFFLINE}" -eq 0 ] || die "--latest needs network access"
		step "resolving the latest upstream master"
		git -C "${clone}" fetch --prune --quiet origin master ||
			die "cannot fetch upstream master"
		REV=$(git -C "${clone}" rev-parse origin/master) ||
			die "cannot resolve origin/master"
		info "upstream master: ${REV}"
	fi

	if [ "${REFRESH}" -eq 1 ] && [ "${OFFLINE}" -eq 0 ]; then
		step "fetching upstream updates"
		run git -C "${clone}" fetch --prune --quiet origin
	fi

	if ! git -C "${clone}" cat-file -e "${REV}^{commit}" 2>/dev/null; then
		die "revision ${REV} is not in the cache; run with --refresh, or delete ${clone}"
	fi

	step "checking out ${REV}"
	run git -C "${clone}" checkout --detach --force --quiet "${REV}"
	run git -C "${clone}" clean -ffdxq

	if ! apply_series "${clone}"; then
		git -C "${clone}" reset --hard --quiet
		git -C "${clone}" clean -ffdxq
		die "upstream changed code this series depends on; the cached tree was reset (see patches/README.md)"
	fi
	write_stamp "${clone}"
	ok "source tree prepared"
	printf '%s\n' "${clone}"
}

require_macos

if [ -n "${SOURCE_OPT}" ]; then
	prepare_external_source "${SOURCE_OPT}"
else
	prepare_cached_source
fi
