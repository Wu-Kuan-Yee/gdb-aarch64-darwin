#!/usr/bin/env bash
#
# Prepare static GMP and MPFR libraries for a self-contained GDB.
#
# The portable build must not link against Homebrew dylibs at run time.  This
# script stages static archives into a private prefix, either by copying the
# archives a Homebrew installation already provides or, when Homebrew is not
# available, by building them from the upstream release tarballs.

set -eu -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

PROG=$(basename -- "$0")
DEPS_DIR="${GAD_CACHE_DIR}/deps"
FORCE=0

GMP_VERSION=6.3.0
GMP_SHA256=a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898
MPFR_VERSION=4.2.2
MPFR_SHA256=b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01

usage()
{
	cat <<EOF
Usage: ${PROG} [options]

Prepare static archives of GMP and MPFR so that the GDB built by
./build.sh --portable only links against macOS system libraries.

Static archives are taken from Homebrew when it provides them (the usual
case, no compilation needed).  Otherwise the pinned upstream tarballs are
downloaded and built with --disable-shared.

Options:
  --prefix DIR   Where to stage the libraries (default: ${DEPS_DIR})
  --force        Rebuild even if the archives are already staged
  -h, --help     Show this help

The result is a prefix per library:

  <prefix>/gmp/include/gmp.h      <prefix>/gmp/lib/libgmp.a
  <prefix>/mpfr/include/mpfr.h    <prefix>/mpfr/lib/libmpfr.a
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--prefix)
			need_value "$1" "$#"
			DEPS_DIR=$2
			shift 2
			;;
		--force)
			FORCE=1
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

REQUESTED_DIR=${DEPS_DIR}
mkdir -p -- "${REQUESTED_DIR}" || die "cannot create ${REQUESTED_DIR}"
DEPS_DIR=$(abspath "${REQUESTED_DIR}") || die "cannot resolve ${REQUESTED_DIR}"

dep_ready()
{
	local dir=$1 header=$2 archive=$3
	[ -f "${dir}/include/${header}" ] && [ -f "${dir}/lib/${archive}" ]
}

# Copy the static archive and headers from a Homebrew installation.
stage_from_brew()
{
	local name=$1 brewdir
	local header archive

	case "${name}" in
		gmp) header=gmp.h; archive=libgmp.a ;;
		mpfr) header=mpfr.h; archive=libmpfr.a ;;
	esac

	brewdir=$(brew_prefix "${name}")
	[ -n "${brewdir}" ] || return 1
	[ -f "${brewdir}/lib/${archive}" ] || return 1
	[ -f "${brewdir}/include/${header}" ] || return 1

	mkdir -p "${DEPS_DIR}/${name}/lib" "${DEPS_DIR}/${name}/include"
	cp -p "${brewdir}/lib/${archive}" "${DEPS_DIR}/${name}/lib/"
	cp -p "${brewdir}/include/${header}" "${DEPS_DIR}/${name}/include/"
	if [ "${name}" = mpfr ] && [ -f "${brewdir}/include/mpf2mpfr.h" ]; then
		cp -p "${brewdir}/include/mpf2mpfr.h" "${DEPS_DIR}/${name}/include/"
	fi
	info "staged ${name} from ${brewdir}"
}

download_tarball()
{
	local name=$1 version=$2 sha=$3
	local tarball="${GAD_CACHE_DIR}/downloads/${name}-${version}.tar.xz"
	local url="https://ftp.gnu.org/gnu/${name}/${name}-${version}.tar.xz"

	mkdir -p "${GAD_CACHE_DIR}/downloads"
	if [ ! -f "${tarball}" ]; then
		step "downloading ${name} ${version}"
		curl -fL --progress-bar "${url}" -o "${tarball}" ||
			die "cannot download ${url}"
	fi

	if [ -n "${sha}" ]; then
		local actual
		actual=$(shasum -a 256 "${tarball}" | awk '{ print $1 }')
		[ "${actual}" = "${sha}" ] ||
			die "checksum mismatch for ${tarball}: ${actual}"
	fi
	printf '%s\n' "${tarball}"
}

# Build a library from its release tarball with shared libraries disabled.
build_from_source()
{
	local name=$1 version=$2 sha=$3
	local tarball srcdir prefix extra

	prefix="${DEPS_DIR}/${name}"
	tarball=$(download_tarball "${name}" "${version}" "${sha}")
	srcdir="${GAD_CACHE_DIR}/downloads/${name}-${version}"

	step "building ${name} ${version}"
	rm -rf -- "${srcdir}"
	tar -xJf "${tarball}" -C "${GAD_CACHE_DIR}/downloads"

	extra=()
	if [ "${name}" = mpfr ]; then
		extra[${#extra[@]}]="--with-gmp=${DEPS_DIR}/gmp"
	fi

	if [ "${#extra[@]}" -gt 0 ]; then
		(
			cd -- "${srcdir}"
			env CC=/usr/bin/cc CXX=/usr/bin/c++ \
				./configure --prefix="${prefix}" \
					--disable-shared --enable-static \
					"${extra[@]}" >"${srcdir}/configure.log" 2>&1
		) || die "configure failed for ${name}; see ${srcdir}/configure.log"
	else
		(
			cd -- "${srcdir}"
			env CC=/usr/bin/cc CXX=/usr/bin/c++ \
				./configure --prefix="${prefix}" \
					--disable-shared --enable-static \
					>"${srcdir}/configure.log" 2>&1
		) || die "configure failed for ${name}; see ${srcdir}/configure.log"
	fi

	(
		cd -- "${srcdir}"
		make -j "${GAD_JOBS:-$(default_jobs)}" >"${srcdir}/build.log" 2>&1 ||
			die "build failed for ${name}; see ${srcdir}/build.log"
		make install >>"${srcdir}/build.log" 2>&1 ||
			die "install failed for ${name}; see ${srcdir}/build.log"
	)
}

ensure_gmp()
{
	if [ "${FORCE}" -eq 0 ] && dep_ready "${DEPS_DIR}/gmp" gmp.h libgmp.a; then
		ok "gmp: ${DEPS_DIR}/gmp"
		return
	fi
	rm -rf -- "${DEPS_DIR}/gmp"
	if ! stage_from_brew gmp; then
		build_from_source gmp "${GMP_VERSION}" "${GMP_SHA256}"
	fi
	dep_ready "${DEPS_DIR}/gmp" gmp.h libgmp.a ||
		die "gmp was not staged correctly"
	ok "gmp: ${DEPS_DIR}/gmp"
}

ensure_mpfr()
{
	if [ "${FORCE}" -eq 0 ] && dep_ready "${DEPS_DIR}/mpfr" mpfr.h libmpfr.a; then
		ok "mpfr: ${DEPS_DIR}/mpfr"
		return
	fi
	rm -rf -- "${DEPS_DIR}/mpfr"
	if ! stage_from_brew mpfr; then
		build_from_source mpfr "${MPFR_VERSION}" "${MPFR_SHA256}"
	fi
	dep_ready "${DEPS_DIR}/mpfr" mpfr.h libmpfr.a ||
		die "mpfr was not staged correctly"
	ok "mpfr: ${DEPS_DIR}/mpfr"
}

step "preparing static libraries in ${DEPS_DIR}"
mkdir -p "${DEPS_DIR}"
ensure_gmp
ensure_mpfr
ok "static dependencies ready"
