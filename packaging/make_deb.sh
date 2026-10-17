#!/usr/bin/env bash
#
# Build two Debian packages from this source tree:
#
#   nvtop      -- the same shape as the package in the Ubuntu archive: the same
#                 package name, section, priority, description and maintainer
#                 scripts, with the dependencies derived from the binary that
#                 was actually built here.
#   nvtop-pin  -- ships an apt preferences file that stops apt from replacing
#                 the locally built nvtop with the archive version.
#
# Needs dpkg-dev (dpkg-architecture, dpkg-shlibdeps), dpkg-deb and whatever
# CMake needs to build nvtop itself.

set -euo pipefail
umask 022

# readlink -f so that invoking the script through a symlink in ~/bin still
# finds the source tree it belongs to.
SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/deb"

OUTPUT_DIR="${REPO_ROOT}/dist"
BUILD_DIR=""
PACKAGE_VERSION=""
DEB_REVISION="${DEB_REVISION:-1}"
JOBS="$(nproc 2>/dev/null || echo 1)"
BUILD_MAIN=1
BUILD_PIN=1
CMAKE_ARGS=()

PIN_FILE_NAME="99-nvtop-local.pref"

usage() {
	cat <<'EOF'
Usage: packaging/make_deb.sh [options] [-- extra cmake args]

  --output-dir=DIR   Where to write the .deb files (default: <repo>/dist)
  --build-dir=DIR    Scratch directory for the CMake tree and the package
                     staging areas (default: <repo>/build/deb)
  --version=VERSION  Package version. Without a Debian revision ("-N"), the
                     revision defaults to 1. Default: the version declared in
                     CMakeLists.txt.
  --jobs=N           Parallel compile jobs (default: nproc)
  --deb-only         Build only the nvtop package
  --pin-only         Build only the nvtop-pin package (no compilation)
  -h, --help         Show this help

Everything after "--" is passed to the CMake configure step, for example:

  packaging/make_deb.sh -- -DNVIDIA_SUPPORT=ON -DAMDGPU_SUPPORT=OFF
EOF
}

die() {
	echo "ERROR: $*" >&2
	exit 1
}

# Consume the value of a space-separated option. Without this, an option given
# as the last argument would shift the stack empty and `set -e` would end the
# script with no output at all.
need_value() {
	[ "$2" -gt 1 ] || die "$1 needs a value"
}

while [ $# -gt 0 ]; do
	case "$1" in
	--output-dir=*) OUTPUT_DIR="${1#*=}" ;;
	--output-dir) need_value "$1" $#; shift; OUTPUT_DIR="$1" ;;
	--build-dir=*) BUILD_DIR="${1#*=}" ;;
	--build-dir) need_value "$1" $#; shift; BUILD_DIR="$1" ;;
	--version=*) PACKAGE_VERSION="${1#*=}" ;;
	--version) need_value "$1" $#; shift; PACKAGE_VERSION="$1" ;;
	--jobs=*) JOBS="${1#*=}" ;;
	--jobs) need_value "$1" $#; shift; JOBS="$1" ;;
	--deb-only) BUILD_PIN=0 ;;
	--pin-only) BUILD_MAIN=0 ;;
	-h | --help) usage; exit 0 ;;
	--) shift; CMAKE_ARGS=("$@"); break ;;
	*) usage >&2; die "unknown argument: $1" ;;
	esac
	shift
done

[ "${BUILD_MAIN}" -eq 1 ] || [ "${BUILD_PIN}" -eq 1 ] ||
	die "--deb-only and --pin-only together leave nothing to build"
[ -n "${OUTPUT_DIR}" ] || die "--output-dir needs a value"
case "${JOBS}" in
*[!0-9]* | "" | 0 | 0*) die "--jobs needs a positive integer, got '${JOBS}'" ;;
esac
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd -- "${OUTPUT_DIR}" && pwd)"
[ -n "${BUILD_DIR}" ] || BUILD_DIR="${REPO_ROOT}/build/deb"

for tool in dpkg-deb dpkg-architecture; do
	command -v "${tool}" >/dev/null 2>&1 || die "${tool} not found; install dpkg-dev"
done

ARCH="$(dpkg-architecture -qDEB_HOST_ARCH)"

# Version: "3.3.2" from `project(nvtop VERSION 3.3.2`, unless overridden.
if [ -z "${PACKAGE_VERSION}" ]; then
	PACKAGE_VERSION="$(sed -n 's/^[[:space:]]*project(nvtop[[:space:]]\+VERSION[[:space:]]\+\([0-9][^[:space:])]*\).*/\1/p' \
		"${REPO_ROOT}/CMakeLists.txt" | head -n1)"
	[ -n "${PACKAGE_VERSION}" ] || die "could not read the project version from CMakeLists.txt"
fi
case "${PACKAGE_VERSION}" in
*-*) FULL_VERSION="${PACKAGE_VERSION}" ;;
*) FULL_VERSION="${PACKAGE_VERSION}-${DEB_REVISION}" ;;
esac

# Debian strips the epoch from the file name; a ':' in it also breaks
# reprepro/dput and cannot be written to vfat or SMB.
FILE_VERSION="${FULL_VERSION#*:}"

# Maintainer: whoever is building, so the package is traceable back to them.
if [ -z "${DEB_MAINTAINER:-}" ]; then
	maintainer_name="$(git -C "${REPO_ROOT}" config user.name 2>/dev/null || true)"
	maintainer_mail="$(git -C "${REPO_ROOT}" config user.email 2>/dev/null || true)"
	if [ -n "${maintainer_name}" ] && [ -n "${maintainer_mail}" ]; then
		DEB_MAINTAINER="${maintainer_name} <${maintainer_mail}>"
	else
		DEB_MAINTAINER="Local build <root@$(hostname -f 2>/dev/null || hostname)>"
	fi
fi
# A newline here would inject arbitrary fields into the control file.
case "${DEB_MAINTAINER}" in
*"
"*) die "DEB_MAINTAINER must be a single line" ;;
esac

# The Debian changelog format wants an English RFC 5322 date. Honouring
# SOURCE_DATE_EPOCH is what makes two builds of the same tree byte-identical.
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
	CHANGELOG_DATE="$(LC_ALL=C date -R -u -d "@${SOURCE_DATE_EPOCH}")"
else
	CHANGELOG_DATE="$(LC_ALL=C date -R)"
fi

# $1 = source package name, $2 = staging directory
write_changelog() {
	local pkg="$1" dir="$2/usr/share/doc/$1"
	install -d -m 0755 "${dir}"
	cat >"${dir}/changelog.Debian" <<EOF
${pkg} (${FULL_VERSION}) UNRELEASED; urgency=medium

  * Local build from the nvtop source tree.

 -- ${DEB_MAINTAINER}  ${CHANGELOG_DATE}
EOF
	gzip -n -9 "${dir}/changelog.Debian"
	install -m 0644 "${TEMPLATE_DIR}/copyright" "${dir}/copyright"
}

# Installed-Size in KiB, using dpkg-gencontrol's rule since dpkg 1.21: each
# file counts as ceil(size / 1024) and each directory as 1. Not `du`, which
# reports whatever the build filesystem felt like -- on btrfs/zfs that is the
# compressed size, which says nothing about the target system. This runs
# before DEBIAN/ exists so the control files are not counted; Policy calls the
# field an estimate, and it lands within a few KiB of what dpkg would say.
# $1 = staging directory
installed_size_kib() {
	find "$1" \( -type d -printf 'd 0\n' \) -o -printf 'f %s\n' |
		awk '$1 == "d" { kib += 1; next } { kib += int(($2 + 1023) / 1024) } END { print kib + 0 }'
}

# Drop anything listed in ./DEBIAN/conffiles from a NUL-separated path list on
# stdin. grep exits 1 when it selects nothing, which is not an error here.
filter_out_conffiles() {
	local patterns
	if [ ! -f DEBIAN/conffiles ]; then
		cat
		return
	fi
	# Not a process substitution: its exit status is invisible to pipefail, so
	# a failing sed would silently degrade to "filter nothing".
	patterns="$(sed 's|^/||' DEBIAN/conffiles)"
	[ -n "${patterns}" ] || { cat; return; }
	grep -zvxF -- "${patterns}" || [ $? -eq 1 ]
}

# $1 = staging directory. Must run after every payload file is in place.
# Conffiles are left out, as dh_md5sums does: they are meant to be edited, and
# listing them makes `dpkg --verify` report an edited package as corrupt.
write_md5sums() {
	local stage="$1"
	(cd "${stage}" && find . -type f -not -path './DEBIAN/*' -printf '%P\0' |
		LC_ALL=C sort -z | filter_out_conffiles |
		xargs -0 -r md5sum >DEBIAN/md5sums)
	chmod 0644 "${stage}/DEBIAN/md5sums"
}

# $1 = staging directory, $2 = output .deb path
build_deb() {
	local stage="$1" out="$2"
	chmod 0755 "${stage}/DEBIAN"
	dpkg-deb --build --root-owner-group "${stage}" "${out}" >/dev/null
	echo "Wrote ${out}"
}

build_nvtop_deb() {
	local stage="${BUILD_DIR}/stage-nvtop"

	echo "==> Building nvtop ${FULL_VERSION} (${ARCH})"
	command -v dpkg-shlibdeps >/dev/null 2>&1 || die "dpkg-shlibdeps not found; install dpkg-dev"

	cmake -S "${REPO_ROOT}" -B "${BUILD_DIR}/cmake" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX=/usr \
		${CMAKE_ARGS[@]+"${CMAKE_ARGS[@]}"}
	cmake --build "${BUILD_DIR}/cmake" --parallel "${JOBS}"

	rm -rf "${stage}"
	DESTDIR="${stage}" cmake --install "${BUILD_DIR}/cmake"
	[ -f "${stage}/usr/bin/nvtop" ] || die "cmake --install did not produce usr/bin/nvtop"

	# Archive packages ship a stripped binary; the extra sections are the ones
	# dh_strip removes too.
	if command -v strip >/dev/null 2>&1; then
		strip --strip-unneeded --remove-section=.comment --remove-section=.note \
			"${stage}/usr/bin/nvtop"
	fi

	# The archive package ships a compressed man page; -n keeps the gzip
	# header free of a timestamp so repeated builds produce identical bytes.
	if [ -f "${stage}/usr/share/man/man1/nvtop.1" ]; then
		gzip -n -9 "${stage}/usr/share/man/man1/nvtop.1"
	fi

	write_changelog nvtop "${stage}"

	local installed_size
	installed_size="$(installed_size_kib "${stage}")"

	# Derive the library dependencies from the binary that was just built,
	# rather than hardcoding the ones the archive build happens to need.
	# dpkg-shlibdeps wants a debian/control next to the tree it inspects.
	install -d -m 0755 "${stage}/debian"
	printf 'Source: nvtop\n\nPackage: nvtop\nArchitecture: any\n' >"${stage}/debian/control"
	local shlib_depends
	shlib_depends="$( (cd "${stage}" && dpkg-shlibdeps -O usr/bin/nvtop) |
		sed -n 's/^shlibs:Depends=//p')"
	rm -rf "${stage}/debian"
	[ -n "${shlib_depends}" ] || die "dpkg-shlibdeps produced no dependencies"
	# libcap2-bin provides the setcap called from postinst. hicolor-icon-theme
	# owns /usr/share/icons/hicolor/index.theme, without which
	# update-icon-caches skips the directory the icon is installed into.
	local depends="${shlib_depends}, libcap2-bin, hicolor-icon-theme"

	install -d -m 0755 "${stage}/DEBIAN"
	cat >"${stage}/DEBIAN/control" <<EOF
Package: nvtop
Version: ${FULL_VERSION}
Architecture: ${ARCH}
Maintainer: ${DEB_MAINTAINER}
Installed-Size: ${installed_size}
Depends: ${depends}
Section: utils
Priority: optional
Homepage: https://github.com/Syllo/nvtop
Description: Neat Videocard TOP
 NVTOP stands for Neat Videocard TOP, a (h)top like task monitor for AMD, Intel
 and NVIDIA GPUs. It can handle multiple GPUs and print information
 about them in a htop-familiar way.
 .
 This package was built from a local nvtop source tree.
EOF
	chmod 0644 "${stage}/DEBIAN/control"
	install -m 0755 "${TEMPLATE_DIR}/nvtop.postinst" "${stage}/DEBIAN/postinst"
	install -m 0755 "${TEMPLATE_DIR}/nvtop.postrm" "${stage}/DEBIAN/postrm"

	write_md5sums "${stage}"
	build_deb "${stage}" "${OUTPUT_DIR}/nvtop_${FILE_VERSION}_${ARCH}.deb"
}

build_pin_deb() {
	local stage="${BUILD_DIR}/stage-nvtop-pin"

	echo "==> Building nvtop-pin ${FULL_VERSION} (all)"
	rm -rf "${stage}"
	install -d -m 0755 "${stage}/etc/apt/preferences.d"
	install -m 0644 "${TEMPLATE_DIR}/nvtop-local.pref" \
		"${stage}/etc/apt/preferences.d/${PIN_FILE_NAME}"

	write_changelog nvtop-pin "${stage}"

	local installed_size
	installed_size="$(installed_size_kib "${stage}")"

	install -d -m 0755 "${stage}/DEBIAN"
	cat >"${stage}/DEBIAN/control" <<EOF
Package: nvtop-pin
Source: nvtop
Version: ${FULL_VERSION}
Architecture: all
Maintainer: ${DEB_MAINTAINER}
Installed-Size: ${installed_size}
Section: utils
Priority: optional
Homepage: https://github.com/Syllo/nvtop
Description: Keep apt from replacing a locally built nvtop
 Installs /etc/apt/preferences.d/${PIN_FILE_NAME}, which gives every
 repository version of the nvtop package a negative priority. A locally built
 nvtop .deb then stays installed: apt upgrade and apt full-upgrade will not
 pull the distribution's nvtop over the top of it.
 .
 While this package is installed, nvtop cannot be installed from any
 repository either. The pin file is a conffile, so purge this package
 (apt-get purge nvtop-pin) to drop the pin; removing it leaves the file
 behind.
EOF
	chmod 0644 "${stage}/DEBIAN/control"
	printf '/etc/apt/preferences.d/%s\n' "${PIN_FILE_NAME}" >"${stage}/DEBIAN/conffiles"
	chmod 0644 "${stage}/DEBIAN/conffiles"

	write_md5sums "${stage}"
	build_deb "${stage}" "${OUTPUT_DIR}/nvtop-pin_${FILE_VERSION}_all.deb"
}

if [ "${BUILD_MAIN}" -eq 1 ]; then
	build_nvtop_deb
fi
if [ "${BUILD_PIN}" -eq 1 ]; then
	build_pin_deb
fi

install_args=""
if [ "${BUILD_MAIN}" -eq 1 ]; then
	install_args="${install_args} '${OUTPUT_DIR}/nvtop_${FILE_VERSION}_${ARCH}.deb'"
fi
if [ "${BUILD_PIN}" -eq 1 ]; then
	install_args="${install_args} '${OUTPUT_DIR}/nvtop-pin_${FILE_VERSION}_all.deb'"
fi
echo
echo "Install with:"
echo "  sudo dpkg -i${install_args}"
