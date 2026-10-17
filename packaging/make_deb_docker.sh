#!/usr/bin/env bash
# Build the nvtop Debian packages against an explicit Ubuntu ABI baseline,
# inside Docker.
#
# packaging/make_deb.sh on its own produces a package for the machine that ran
# it: dpkg-shlibdeps reads the dependency versions off the binary it just
# built, so a package built on Ubuntu 26.04 can demand a glibc that an Ubuntu
# 24.04 node does not have. Building in a container of the target release is
# what makes the artifact installable there.
#
#   packaging/make_deb_docker.sh                       # Ubuntu 24.04
#   packaging/make_deb_docker.sh --target-ubuntu=26.04
#
# The container only ever sees `git archive HEAD`, never the working tree, so
# the package contents match a commit rather than whatever is lying around.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

TARGET_UBUNTU="${TARGET_UBUNTU:-24.04}"
OUTPUT_DIR=""
PACKAGE_VERSION=""
JOBS="$(nproc 2>/dev/null || echo 1)"
EXTRA_ARGS=()

usage() {
	cat <<'EOF'
Usage: packaging/make_deb_docker.sh [options] [-- extra make_deb.sh args]

  --target-ubuntu=VER  Ubuntu release to build against: 22.04, 24.04 or 26.04
                       (default: 24.04)
  --output-dir=DIR     Where to write the .deb files
                       (default: <repo>/dist/ubuntu<VER>)
  --version=VERSION    Package version (default: the one in CMakeLists.txt)
  --jobs=N             Parallel compile jobs (default: nproc)
  -h, --help           Show this help

The build runs against `git archive HEAD`, so the working tree must have no
tracked modifications. SOURCE_DATE_EPOCH is passed through if set.
EOF
}

die() {
	echo "ERROR: $*" >&2
	exit 1
}

need_value() {
	[ "$2" -gt 1 ] || die "$1 needs a value"
}

while [ $# -gt 0 ]; do
	case "$1" in
	--target-ubuntu=*) TARGET_UBUNTU="${1#*=}" ;;
	--target-ubuntu) need_value "$1" $#; shift; TARGET_UBUNTU="$1" ;;
	--output-dir=*) OUTPUT_DIR="${1#*=}" ;;
	--output-dir) need_value "$1" $#; shift; OUTPUT_DIR="$1" ;;
	--version=*) PACKAGE_VERSION="${1#*=}" ;;
	--version) need_value "$1" $#; shift; PACKAGE_VERSION="$1" ;;
	--jobs=*) JOBS="${1#*=}" ;;
	--jobs) need_value "$1" $#; shift; JOBS="$1" ;;
	-h | --help) usage; exit 0 ;;
	--) shift; EXTRA_ARGS=("$@"); break ;;
	*) usage >&2; die "unknown argument: $1" ;;
	esac
	shift
done

case "${TARGET_UBUNTU}" in
22.04 | 24.04 | 26.04) ;;
*) die "--target-ubuntu must be 22.04, 24.04 or 26.04, got '${TARGET_UBUNTU}'" ;;
esac
case "${JOBS}" in
*[!0-9]* | "") die "--jobs needs a positive integer, got '${JOBS}'" ;;
esac
[ "$((10#${JOBS}))" -gt 0 ] || die "--jobs needs a positive integer, got '${JOBS}'"

ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
command -v docker >/dev/null 2>&1 || die "docker not found"
command -v git >/dev/null 2>&1 || die "git not found"
git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1 ||
	die "${REPO_ROOT} is not a git checkout; this build packages git archive HEAD"

# The container builds from HEAD, so uncommitted work would silently not be in
# the package. Refuse rather than ship something that matches no commit.
if ! git -C "${REPO_ROOT}" diff --quiet HEAD -- || ! git -C "${REPO_ROOT}" diff --cached --quiet; then
	die "refusing to build with tracked changes: commit or stash them first"
fi
SOURCE_REVISION="$(git -C "${REPO_ROOT}" rev-parse HEAD)"

[ -n "${OUTPUT_DIR}" ] || OUTPUT_DIR="${REPO_ROOT}/dist/ubuntu${TARGET_UBUNTU}"
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd -- "${OUTPUT_DIR}" && pwd)"

SOURCE_SNAPSHOT="$(mktemp -d "${TMPDIR:-/tmp}/nvtop-deb-source.XXXXXX")"
cleanup() { rm -rf -- "${SOURCE_SNAPSHOT}"; }
trap cleanup EXIT
git -C "${REPO_ROOT}" archive --format=tar "${SOURCE_REVISION}" | tar -xf - -C "${SOURCE_SNAPSHOT}"

image_tag="nvtop-deb-builder:ubuntu${TARGET_UBUNTU}"
echo "[make_deb_docker] Building ${image_tag}..."
docker build \
	--build-arg "TARGET_UBUNTU=${TARGET_UBUNTU}" \
	--tag "${image_tag}" \
	"${SCRIPT_DIR}/docker"

docker_args=(
	--rm
	--volume "${SOURCE_SNAPSHOT}:/source:ro"
	--volume "${OUTPUT_DIR}:/output"
	--env "JOBS=${JOBS}"
	--env "HOST_UID=$(id -u)"
	--env "HOST_GID=$(id -g)"
)
[ -n "${PACKAGE_VERSION}" ] && docker_args+=(--env "PACKAGE_VERSION=${PACKAGE_VERSION}")
[ -n "${SOURCE_DATE_EPOCH:-}" ] && docker_args+=(--env "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}")
if [ -n "${DEB_MAINTAINER:-}" ]; then
	docker_args+=(--env "DEB_MAINTAINER=${DEB_MAINTAINER}")
else
	maintainer_name="$(git -C "${REPO_ROOT}" config user.name 2>/dev/null || true)"
	maintainer_mail="$(git -C "${REPO_ROOT}" config user.email 2>/dev/null || true)"
	if [ -n "${maintainer_name}" ] && [ -n "${maintainer_mail}" ]; then
		docker_args+=(--env "DEB_MAINTAINER=${maintainer_name} <${maintainer_mail}>")
	fi
fi

echo "[make_deb_docker] Building nvtop for Ubuntu ${TARGET_UBUNTU} from ${SOURCE_REVISION:0:12}..."
docker run "${docker_args[@]}" "${image_tag}" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}

shopt -s nullglob
produced=("${OUTPUT_DIR}"/nvtop_*.deb)
shopt -u nullglob
[ "${#produced[@]}" -gt 0 ] || die "docker completed without writing a package to ${OUTPUT_DIR}"
if [ -n "${PACKAGE_VERSION}" ]; then
	# make_deb.sh appends a Debian revision when the caller omitted one and
	# drops the epoch from file names; match what it actually wrote.
	expected_version="${PACKAGE_VERSION}"
	case "${expected_version}" in
	*-*) ;;
	*) expected_version="${expected_version}-1" ;;
	esac
	expected_version="${expected_version#*:}"
	[ -f "${OUTPUT_DIR}/nvtop_${expected_version}_${ARCH}.deb" ] ||
		die "docker completed without writing nvtop_${expected_version}_${ARCH}.deb to ${OUTPUT_DIR}"
fi

echo
echo "Package output directory: ${OUTPUT_DIR}"
