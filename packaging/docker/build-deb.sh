#!/usr/bin/env bash
# Container entrypoint for the Debian package build.
#
# /source is a read-only snapshot of the source tree, /output is the host's
# package directory, /build is scratch. Everything after the fixed arguments
# is forwarded to make_deb.sh.
set -euo pipefail

if [ ! -x /source/packaging/make_deb.sh ]; then
	echo "ERROR: /source does not look like an nvtop source tree" >&2
	exit 1
fi

args=(--output-dir=/output --build-dir=/build)
[ -n "${PACKAGE_VERSION:-}" ] && args+=(--version="${PACKAGE_VERSION}")
[ -n "${JOBS:-}" ] && args+=(--jobs="${JOBS}")

# The snapshot has no .git, so make_deb.sh cannot read a maintainer from it.
export DEB_MAINTAINER="${DEB_MAINTAINER:-Local build <root@nvtop-deb-builder>}"

status=0
/source/packaging/make_deb.sh "${args[@]}" "$@" || status=$?

# The build runs as root; hand the artifacts back to whoever invoked Docker.
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
	chown -R -- "${HOST_UID}:${HOST_GID}" /output
fi

exit "${status}"
