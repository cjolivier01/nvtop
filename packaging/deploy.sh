#!/usr/bin/env bash
# Build nvtop packages and install them on SSH nodes, or remove them again.
#
#   make deploy   NODES=node1,node2
#   make undeploy NODES=node1,node2
#
# Each node is detected over SSH, one package is built per distinct Ubuntu
# release in the set (in a container of that release, so the binary matches
# the node's ABI), uploaded, and installed with apt so the dependencies
# resolve. Nodes need non-interactive SSH and passwordless sudo.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

SSH_CONNECT_TIMEOUT="${NVTOP_DEPLOY_SSH_CONNECT_TIMEOUT:-10}"
DEPLOY_OUTPUT_DIR="${DEPLOY_OUTPUT_DIR:-${REPO_ROOT}/dist}"
NODES_CSV="${NODES:-}"
REQUESTED_PACKAGE_VERSION="${PACKAGE_VERSION:-}"
DEPLOY_PIN="${DEPLOY_PIN:-1}"
DEPLOY_JOBS="${DEPLOY_JOBS:-}"
OPERATION="deploy"

SSH_OPTS=(-o BatchMode=yes -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}")
# Extra options for every ssh and scp call, word-split like CFLAGS. For nodes
# that need a jump host, a non-default port or a specific key:
#   NVTOP_DEPLOY_SSH_OPTS='-J bastion -i ~/.ssh/lab' make deploy NODES=...
if [ -n "${NVTOP_DEPLOY_SSH_OPTS:-}" ]; then
	read -r -a nvtop_deploy_extra_ssh_opts <<<"${NVTOP_DEPLOY_SSH_OPTS}"
	SSH_OPTS+=("${nvtop_deploy_extra_ssh_opts[@]}")
fi

declare -a NODES_LIST=()
declare -a TARGET_KEYS=()
declare -A SEEN_NODES=()
declare -A SEEN_TARGETS=()
declare -A NODE_OS=()
declare -A NODE_TARGET=()
declare -A NODE_PREVIOUS=()
declare -A NODE_RESIDUE=()
declare -A NODE_INSTALLED=()
declare -A NODE_RESULT=()
declare -A NODE_DETAIL=()
declare -A TARGET_DEB=()
declare -A TARGET_PIN_DEB=()
declare -A TARGET_BUILD_ERROR=()

PACKAGE_VERSION_RESOLVED=""
PACKAGE_FILE_VERSION=""
HOST_ARCH=""

usage() {
	cat <<'EOF'
Usage:
  make deploy   NODES=node1,node2[,node3]
  make undeploy NODES=node1,node2[,node3]

Detects each node over SSH, builds one package per distinct Ubuntu release in
the set using packaging/make_deb_docker.sh, uploads it, and installs it with
apt. Nodes must allow non-interactive SSH and passwordless sudo.

Undeploy purges nvtop and nvtop-pin (purge, so the apt pin file goes too).
It does not check where the installed nvtop came from: on a node running the
distribution's package, undeploy removes that. It leaves shared dependencies
installed.

Optional make variables:
  PACKAGE_VERSION=VERSION  Override the derived package version.
  DEPLOY_OUTPUT_DIR=DIR    Package output root (default: dist).
  DEPLOY_PIN=0             Do not install nvtop-pin alongside nvtop.
  CMAKE_JOBS=N             Parallel compile jobs for the container builds
                           (or just use make -j N).

Environment:
  NVTOP_DEPLOY_SSH_OPTS             Extra ssh/scp options, e.g. '-J bastion'.
                                    Word-split, so no option value may
                                    contain a space.
                                    Use '-o Port=N', not '-p': scp reads -p
                                    as preserve-times. Appended after the
                                    built-in options, so BatchMode and
                                    ConnectTimeout cannot be overridden here.
  NVTOP_DEPLOY_SSH_CONNECT_TIMEOUT  SSH connect timeout, seconds (default 10).
  DEB_MAINTAINER                    Package maintainer; defaults to the git
                                    identity of this checkout.

Supported nodes are Ubuntu 22.04, 24.04 and 26.04 (and derivatives, matched on
UBUNTU_CODENAME) on the same architecture as this machine. Cross-architecture
deployment is not supported: the containers build natively.
EOF
}

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	printf '%s' "${value%"${value##*[![:space:]]}"}"
}

parse_nodes() {
	local nodes_csv="$1"
	local -a raw_nodes=()
	local raw_node node

	if [ -z "$(trim "${nodes_csv}")" ]; then
		printf 'ERROR: NODES is required. Usage: make %s NODES=node1,node2\n' "${OPERATION}" >&2
		return 2
	fi
	case "${nodes_csv}" in
	,* | *, | *,,*)
		printf 'ERROR: NODES contains an empty node name: %s\n' "${nodes_csv}" >&2
		return 2
		;;
	esac
	IFS=',' read -r -a raw_nodes <<<"${nodes_csv}"
	for raw_node in "${raw_nodes[@]}"; do
		node="$(trim "${raw_node}")"
		if [ -z "${node}" ]; then
			printf 'ERROR: NODES contains an empty node name: %s\n' "${nodes_csv}" >&2
			return 2
		fi
		# Keeps an option-looking or shell-special name from reaching ssh.
		if [[ ! "${node}" =~ ^[A-Za-z0-9_.-]+(@[A-Za-z0-9_.-]+)?$ ]] || [[ "${node}" == -* ]]; then
			printf 'ERROR: invalid SSH node in NODES: %s\n' "${node}" >&2
			return 2
		fi
		if [ -n "${SEEN_NODES[${node}]+set}" ]; then
			printf 'ERROR: duplicate node in NODES: %s\n' "${node}" >&2
			return 2
		fi
		SEEN_NODES["${node}"]=1
		NODES_LIST+=("${node}")
	done
}

# Ubuntu derivatives keep their own ID and VERSION_ID, and some use a
# VERSION_ID unrelated to any Ubuntu release, so UBUNTU_CODENAME is the only
# trustworthy signal. Only releases we can build a container for are mapped.
ubuntu_release() {
	local os_id="$1" os_version="$2" id_like="$3" codename="$4"
	if [ "${os_id}" = ubuntu ]; then
		printf '%s' "${os_version}"
		return 0
	fi
	case " ${id_like} " in
	*" ubuntu "*) ;;
	*) return 1 ;;
	esac
	case "${codename}" in
	jammy) printf '22.04' ;;
	noble) printf '24.04' ;;
	resolute) printf '26.04' ;;
	*) return 1 ;;
	esac
}

# make_deb_docker.sh packages git archive HEAD and refuses a dirty tree. It
# only reaches that check after every node has been contacted, so repeat it
# here before anything slow or remote happens.
require_clean_repository() {
	if ! git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
		printf 'ERROR: %s is not a git checkout; deploy packages git archive HEAD.\n' "${REPO_ROOT}" >&2
		return 1
	fi
	if ! git -C "${REPO_ROOT}" rev-parse --verify -q HEAD >/dev/null; then
		printf 'ERROR: %s has no commits; deploy packages git archive HEAD.\n' "${REPO_ROOT}" >&2
		return 1
	fi
	if ! git -C "${REPO_ROOT}" diff --quiet HEAD -- || ! git -C "${REPO_ROOT}" diff --cached --quiet; then
		printf 'ERROR: refusing to deploy with tracked changes: commit or stash them first.\n' >&2
		return 1
	fi
}

require_local_commands() {
	local command_name
	local -a required=(git ssh sed)
	[ "${OPERATION}" = deploy ] && required+=(scp docker dpkg)
	for command_name in "${required[@]}"; do
		command -v "${command_name}" >/dev/null 2>&1 || {
			printf 'ERROR: required command not found: %s\n' "${command_name}" >&2
			return 1
		}
	done
	case "${SSH_CONNECT_TIMEOUT}" in
	*[!0-9]* | "" | 0) printf 'ERROR: NVTOP_DEPLOY_SSH_CONNECT_TIMEOUT must be a positive integer.\n' >&2; return 1 ;;
	esac
}

detect_node() {
	local node="$1"
	local output identity marker os_id os_version id_like codename architecture previous residue extra release

	printf '\n[%s] Detecting %s...\n' "${OPERATION}" "${node}"
	if ! output="$(ssh "${SSH_OPTS[@]}" "${node}" bash -s <<'REMOTE_DETECT'
set -eu
[ -r /etc/os-release ] || { echo "ERROR: /etc/os-release is unavailable" >&2; exit 1; }
. /etc/os-release
installed=""
if [ "$(dpkg-query -W -f='${db:Status-Status}' nvtop 2>/dev/null || true)" = installed ]; then
  installed="$(dpkg-query -W -f='${Version}' nvtop)"
fi
# Anything undeploy would purge, including a config-files remnant and a
# stand-alone nvtop-pin: either still owns /etc/apt/preferences.d.
residue=""
for package in nvtop nvtop-pin; do
  status="$(dpkg-query -W -f='${db:Status-Status}' "${package}" 2>/dev/null || true)"
  if [ -n "${status}" ] && [ "${status}" != "not-installed" ]; then residue="yes"; fi
done
printf '__NVTOP_DEPLOY__|%s|%s|%s|%s|%s|%s|%s\n' \
  "${ID:-}" "${VERSION_ID:-}" "${ID_LIKE:-}" "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" \
  "$(dpkg --print-architecture)" "${installed}" "${residue}"
REMOTE_DETECT
	)"; then
		NODE_OS["${node}"]="unknown"
		NODE_RESULT["${node}"]="FAILED"
		NODE_DETAIL["${node}"]="SSH or OS detection failed"
		printf '[%s] ERROR: %s: SSH or OS detection failed\n' "${OPERATION}" "${node}" >&2
		return 1
	fi

	identity="$(printf '%s\n' "${output}" | sed -n '/^__NVTOP_DEPLOY__|/p' | tail -n 1)"
	IFS='|' read -r marker os_id os_version id_like codename architecture previous residue extra <<<"${identity}"
	if [ "${marker:-}" != "__NVTOP_DEPLOY__" ] || [ -n "${extra:-}" ]; then
		NODE_OS["${node}"]="unknown"
		NODE_RESULT["${node}"]="FAILED"
		NODE_DETAIL["${node}"]="invalid OS detection response"
		printf '[%s] ERROR: %s: invalid OS detection response\n' "${OPERATION}" "${node}" >&2
		return 1
	fi

	NODE_OS["${node}"]="${os_id:-unknown} ${os_version:-unknown} ${architecture:-unknown}"
	NODE_PREVIOUS["${node}"]="${previous:-}"
	NODE_INSTALLED["${node}"]="${previous:-}"
	NODE_RESIDUE["${node}"]="${residue:-}"

	# Removing packages needs no build, so undeploy does not care which
	# release or architecture the node is: refusing to clean up a node we
	# can no longer build for would be the wrong way round.
	if [ "${OPERATION}" != deploy ]; then
		printf '[%s] %s: %s, installed nvtop: %s\n' \
			"${OPERATION}" "${node}" "${NODE_OS[${node}]}" "${previous:-not installed}"
		return 0
	fi

	if ! release="$(ubuntu_release "${os_id}" "${os_version}" "${id_like}" "${codename}")" ||
		[ -z "${release}" ]; then
		NODE_TARGET["${node}"]="unsupported"
		NODE_RESULT["${node}"]="FAILED"
		NODE_DETAIL["${node}"]="unsupported distribution ${os_id:-?} ${os_version:-?}"
		printf '[%s] ERROR: %s: %s\n' "${OPERATION}" "${node}" "${NODE_DETAIL[${node}]}" >&2
		return 1
	fi
	case "${release}" in
	22.04 | 24.04 | 26.04) ;;
	*)
		NODE_TARGET["${node}"]="unsupported"
		NODE_RESULT["${node}"]="FAILED"
		NODE_DETAIL["${node}"]="no builder image for Ubuntu ${release}"
		printf '[%s] ERROR: %s: %s\n' "${OPERATION}" "${node}" "${NODE_DETAIL[${node}]}" >&2
		return 1
		;;
	esac
	if [ "${architecture}" != "${HOST_ARCH}" ]; then
		NODE_TARGET["${node}"]="unsupported"
		NODE_RESULT["${node}"]="FAILED"
		NODE_DETAIL["${node}"]="architecture ${architecture} != build host ${HOST_ARCH}"
		printf '[%s] ERROR: %s: %s\n' "${OPERATION}" "${node}" "${NODE_DETAIL[${node}]}" >&2
		return 1
	fi

	NODE_TARGET["${node}"]="ubuntu${release}-${architecture}"
	if [ -z "${SEEN_TARGETS[${NODE_TARGET[${node}]}]+set}" ]; then
		SEEN_TARGETS["${NODE_TARGET[${node}]}"]=1
		TARGET_KEYS+=("${NODE_TARGET[${node}]}")
	fi
	printf '[%s] %s: %s, installed nvtop: %s\n' \
		"${OPERATION}" "${node}" "${NODE_OS[${node}]}" "${previous:-not installed}"
}

# Package version: the project version with the commit folded into the Debian
# revision, so a redeploy of a later commit is an upgrade rather than a
# reinstall and the summary says which build is on each node. Note this still
# loses to a distribution revision of -2 or higher, which is what nvtop-pin is
# for; it only outranks -1 and the Ubuntu-style -1ubuntu1 / -1build1 forms.
derive_package_version() {
	local base commit_epoch short_hash
	if [ -n "${REQUESTED_PACKAGE_VERSION}" ]; then
		PACKAGE_VERSION_RESOLVED="${REQUESTED_PACKAGE_VERSION}"
	else
		base="$(sed -n 's/^[[:space:]]*project(nvtop[[:space:]]\+VERSION[[:space:]]\+\([0-9][^[:space:])]*\).*/\1/p' \
			"${REPO_ROOT}/CMakeLists.txt" | head -n1)"
		[ -n "${base}" ] || { printf 'ERROR: could not read the project version from CMakeLists.txt\n' >&2; return 1; }
		if ! commit_epoch="$(git -C "${REPO_ROOT}" show -s --format=%ct HEAD 2>/dev/null)" ||
			! short_hash="$(git -C "${REPO_ROOT}" rev-parse --short=7 HEAD 2>/dev/null)"; then
			printf 'ERROR: could not derive a package version from git HEAD in %s.\n' "${REPO_ROOT}" >&2
			printf '       Pass PACKAGE_VERSION=VERSION to set one explicitly.\n' >&2
			return 1
		fi
		PACKAGE_VERSION_RESOLVED="${base}-1+git${commit_epoch}.${short_hash}"
	fi
	# Validate what the caller actually typed, before normalizing, so the
	# error quotes their string rather than a mangled one.
	if ! dpkg --validate-version "${PACKAGE_VERSION_RESOLVED}" >/dev/null 2>&1; then
		printf 'ERROR: invalid package version: %s\n' "${PACKAGE_VERSION_RESOLVED}" >&2
		return 1
	fi
	# Apply exactly the normalization make_deb.sh does, or the filenames this
	# script predicts will not be the ones the build writes: a version with no
	# Debian revision gains "-1", and the epoch is stripped from file names.
	case "${PACKAGE_VERSION_RESOLVED}" in
	*-*) ;;
	*) PACKAGE_VERSION_RESOLVED="${PACKAGE_VERSION_RESOLVED}-1" ;;
	esac
	PACKAGE_FILE_VERSION="${PACKAGE_VERSION_RESOLVED#*:}"
}

build_target() {
	local target_key="$1"
	local release="${target_key#ubuntu}"
	release="${release%-*}"
	local output_dir="${DEPLOY_OUTPUT_DIR}/ubuntu${release}"
	local deb pin_deb

	printf '\n[deploy] Building nvtop %s for Ubuntu %s...\n' "${PACKAGE_VERSION_RESOLVED}" "${release}"
	if ! "${SCRIPT_DIR}/make_deb_docker.sh" \
		--target-ubuntu="${release}" \
		--output-dir="${output_dir}" \
		${DEPLOY_JOBS:+--jobs="${DEPLOY_JOBS}"} \
		--version="${PACKAGE_VERSION_RESOLVED}"; then
		TARGET_BUILD_ERROR["${target_key}"]="package build failed for Ubuntu ${release}"
		return 1
	fi

	deb="${output_dir}/nvtop_${PACKAGE_FILE_VERSION}_${HOST_ARCH}.deb"
	pin_deb="${output_dir}/nvtop-pin_${PACKAGE_FILE_VERSION}_all.deb"
	if [ ! -f "${deb}" ]; then
		TARGET_BUILD_ERROR["${target_key}"]="expected package missing: ${deb}"
		return 1
	fi
	if [ "${DEPLOY_PIN}" = 1 ] && [ ! -f "${pin_deb}" ]; then
		TARGET_BUILD_ERROR["${target_key}"]="expected pin package missing: ${pin_deb}"
		return 1
	fi
	TARGET_DEB["${target_key}"]="${deb}"
	[ "${DEPLOY_PIN}" = 1 ] && TARGET_PIN_DEB["${target_key}"]="${pin_deb}"
	return 0
}

query_installed_version() {
	local node="$1" output
	output="$(ssh "${SSH_OPTS[@]}" "${node}" \
		'v=; if [ "$(dpkg-query -W -f="\${db:Status-Status}" nvtop 2>/dev/null || true)" = installed ]; then v=$(dpkg-query -W -f="\${Version}" nvtop); fi; printf "__NVTOP_VERSION__|%s\n" "$v"')" || return 1
	printf '%s' "$(printf '%s\n' "${output}" | sed -n 's/^__NVTOP_VERSION__|//p' | tail -n 1)"
}

create_remote_directory() {
	local node="$1" output remote_dir
	output="$(ssh "${SSH_OPTS[@]}" "${node}" 'mktemp -d /tmp/nvtop-deploy.XXXXXX')" || return 1
	remote_dir="$(printf '%s\n' "${output}" | tail -n 1)"
	if [[ ! "${remote_dir}" =~ ^/tmp/nvtop-deploy\.[A-Za-z0-9]+$ ]]; then
		printf 'ERROR: %s returned an unsafe deployment directory: %s\n' "${node}" "${remote_dir}" >&2
		return 1
	fi
	printf '%s' "${remote_dir}"
}

cleanup_remote_directory() {
	local node="$1" remote_dir="$2"
	[[ "${remote_dir}" =~ ^/tmp/nvtop-deploy\.[A-Za-z0-9]+$ ]] || return 0
	# Expanding client side is deliberate: the path came from the remote and
	# has just been matched against that pattern, so it holds no metacharacters.
	# shellcheck disable=SC2029
	ssh "${SSH_OPTS[@]}" "${node}" "rm -rf -- '${remote_dir}'" >/dev/null 2>&1 || true
}

deploy_node() {
	local node="$1"
	local target_key="${NODE_TARGET[${node}]}"
	local deb="${TARGET_DEB[${target_key}]:-}"
	local pin_deb="${TARGET_PIN_DEB[${target_key}]:-}"
	local remote_dir names=() installed status=0

	if [ -z "${deb}" ]; then
		NODE_RESULT["${node}"]="FAILED"
		NODE_DETAIL["${node}"]="${TARGET_BUILD_ERROR[${target_key}]:-package unavailable}"
		return 1
	fi

	printf '\n[deploy] Deploying %s to %s...\n' "$(basename "${deb}")" "${node}"
	remote_dir="$(create_remote_directory "${node}")" || {
		NODE_RESULT["${node}"]="FAILED"
		NODE_DETAIL["${node}"]="could not create a remote directory"
		return 1
	}

	names=("$(basename "${deb}")")
	[ -n "${pin_deb}" ] && names+=("$(basename "${pin_deb}")")

	if ! scp "${SSH_OPTS[@]}" "${deb}" ${pin_deb:+"${pin_deb}"} "${node}:${remote_dir}/"; then
		status=1
	elif ! ssh "${SSH_OPTS[@]}" "${node}" bash -s -- "${remote_dir}" "${names[@]}" <<'REMOTE_INSTALL'
set -euo pipefail
remote_dir="$1"
shift
export DEBIAN_FRONTEND=noninteractive
packages=()
for name in "$@"; do packages+=("${remote_dir}/${name}"); done
printf '[deploy] Installing on %s...\n' "$(hostname)"
# Refresh the package lists first: nvtop depends on libcap2-bin and
# hicolor-icon-theme, and a node with empty or stale lists reports them as
# "not installable" even though the archive has them. Non-fatal, because a
# node that cannot reach its mirror can still install if the dependencies are
# already present -- and if they are not, the install below says so.
sudo -n apt-get update || echo "[deploy] WARNING: apt-get update failed; continuing with the existing lists" >&2
# apt rather than dpkg -i so the dependencies resolve; --allow-downgrades so
# redeploying an older commit is not a hard error. The pin package, if it is
# in this set, is installed in the same transaction as nvtop so apt never sees
# a moment where nvtop is pinned away but not yet present.
sudo -n apt-get install -y --no-install-recommends --allow-downgrades --reinstall "${packages[@]}"
REMOTE_INSTALL
	then
		status=1
	fi
	cleanup_remote_directory "${node}" "${remote_dir}"

	if [ "${status}" -ne 0 ]; then
		NODE_RESULT["${node}"]="FAILED"
		NODE_DETAIL["${node}"]="upload or installation failed"
		return 1
	fi

	if ! installed="$(query_installed_version "${node}")"; then
		NODE_INSTALLED["${node}"]=""
		NODE_RESULT["${node}"]="FAILED"
		NODE_DETAIL["${node}"]="installed, but the version could not be read back over SSH"
		return 1
	fi
	# dpkg normalizes a zero epoch away, so compare the way dpkg does rather
	# than as strings: "0:4.0.0-1" installs and reads back as "4.0.0-1".
	if ! dpkg --compare-versions "${installed}" eq "${PACKAGE_VERSION_RESOLVED}"; then
		NODE_INSTALLED["${node}"]="${installed:-unknown}"
		NODE_RESULT["${node}"]="FAILED"
		NODE_DETAIL["${node}"]="post-install verification failed"
		return 1
	fi

	NODE_INSTALLED["${node}"]="${installed}"
	NODE_RESULT["${node}"]="OK"
	if [ -z "${NODE_PREVIOUS[${node}]:-}" ]; then
		NODE_DETAIL["${node}"]="installed"
	elif [ "${NODE_PREVIOUS[${node}]}" = "${installed}" ]; then
		NODE_DETAIL["${node}"]="reinstalled"
	elif dpkg --compare-versions "${NODE_PREVIOUS[${node}]}" lt "${installed}"; then
		NODE_DETAIL["${node}"]="updated"
	else
		NODE_DETAIL["${node}"]="downgraded"
	fi
	printf '[deploy] %s: nvtop %s (%s).\n' "${node}" "${installed}" "${NODE_DETAIL[${node}]}"
}

undeploy_node() {
	local node="$1" installed

	printf '\n[undeploy] Removing nvtop from %s...\n' "${node}"
	if ! ssh "${SSH_OPTS[@]}" "${node}" bash -s <<'REMOTE_UNDEPLOY'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
packages=()
for package in nvtop nvtop-pin; do
  status="$(dpkg-query -W -f='${db:Status-Status}' "${package}" 2>/dev/null || true)"
  # Purge config-files remnants too, so the apt pin really goes away.
  if [ -n "${status}" ] && [ "${status}" != "not-installed" ]; then packages+=("${package}"); fi
done
if [ "${#packages[@]}" -gt 0 ]; then
  sudo -n apt-get remove --purge -y "${packages[@]}"
fi
REMOTE_UNDEPLOY
	then
		NODE_RESULT["${node}"]="FAILED"
		NODE_DETAIL["${node}"]="package removal failed"
		return 1
	fi

	installed="$(query_installed_version "${node}")" || {
		NODE_RESULT["${node}"]="FAILED"
		NODE_DETAIL["${node}"]="post-removal verification failed"
		return 1
	}
	if [ -n "${installed}" ]; then
		NODE_INSTALLED["${node}"]="${installed}"
		NODE_RESULT["${node}"]="FAILED"
		NODE_DETAIL["${node}"]="nvtop ${installed} remains installed"
		return 1
	fi

	NODE_INSTALLED["${node}"]=""
	NODE_RESULT["${node}"]="OK"
	if [ -n "${NODE_PREVIOUS[${node}]:-}" ]; then
		NODE_DETAIL["${node}"]="removed"
	elif [ -n "${NODE_RESIDUE[${node}]:-}" ]; then
		# No installed nvtop, but a config-files remnant or a lone nvtop-pin
		# was purged -- which is what takes the apt pin file away.
		NODE_DETAIL["${node}"]="purged leftovers"
	else
		NODE_DETAIL["${node}"]="already absent"
	fi
	printf '[undeploy] %s: %s.\n' "${node}" "${NODE_DETAIL[${node}]}"
}

print_summary() {
	local node previous installed result os
	local w_node=4 w_os=2 w_prev=8 w_inst=9 w_res=6

	for node in "${NODES_LIST[@]}"; do
		previous="${NODE_PREVIOUS[${node}]:---}"
		installed="${NODE_INSTALLED[${node}]:---}"
		result="${NODE_RESULT[${node}]:-FAILED}: ${NODE_DETAIL[${node}]:-not attempted}"
		((${#node} > w_node)) && w_node=${#node}
		os="${NODE_OS[${node}]:-unknown}"
		((${#os} > w_os)) && w_os=${#os}
		((${#previous} > w_prev)) && w_prev=${#previous}
		((${#installed} > w_inst)) && w_inst=${#installed}
		((${#result} > w_res)) && w_res=${#result}
	done

	printf '\n%s summary\n' "$([ "${OPERATION}" = undeploy ] && printf 'Undeployment' || printf 'Deployment')"
	printf '%-*s  %-*s  %-*s  %-*s  %-*s\n' \
		"${w_node}" NODE "${w_os}" OS "${w_prev}" PREVIOUS "${w_inst}" INSTALLED "${w_res}" RESULT
	printf '%*s  %*s  %*s  %*s  %*s\n' \
		"${w_node}" '' "${w_os}" '' "${w_prev}" '' "${w_inst}" '' "${w_res}" '' | tr ' ' '-'
	for node in "${NODES_LIST[@]}"; do
		printf '%-*s  %-*s  %-*s  %-*s  %-*s\n' \
			"${w_node}" "${node}" \
			"${w_os}" "${NODE_OS[${node}]:-unknown}" \
			"${w_prev}" "${NODE_PREVIOUS[${node}]:---}" \
			"${w_inst}" "${NODE_INSTALLED[${node}]:---}" \
			"${w_res}" "${NODE_RESULT[${node}]:-FAILED}: ${NODE_DETAIL[${node}]:-not attempted}"
	done
}

main() {
	local node target_key overall_status=0

	while [ $# -gt 0 ]; do
		case "$1" in
		--nodes=*) NODES_CSV="${1#*=}" ;;
		--nodes)
			[ $# -gt 1 ] || { printf 'ERROR: --nodes requires a value.\n' >&2; return 2; }
			shift
			NODES_CSV="$1"
			;;
		--undeploy) OPERATION="undeploy" ;;
		-h | --help) usage; return 0 ;;
		*) printf 'ERROR: unknown option: %s\n' "$1" >&2; usage >&2; return 2 ;;
		esac
		shift
	done

	parse_nodes "${NODES_CSV}" || return $?
	require_local_commands || return 1
	if [ "${OPERATION}" = deploy ]; then
		require_clean_repository || return 1
		HOST_ARCH="$(dpkg --print-architecture)"
		derive_package_version || return 1
		printf '[deploy] Package version: %s\n' "${PACKAGE_VERSION_RESOLVED}"
	fi

	for node in "${NODES_LIST[@]}"; do
		detect_node "${node}" || overall_status=1
	done

	if [ "${OPERATION}" = undeploy ]; then
		for node in "${NODES_LIST[@]}"; do
			[ -n "${NODE_RESULT[${node}]:-}" ] && continue
			undeploy_node "${node}" || overall_status=1
		done
		print_summary
		return "${overall_status}"
	fi

	for target_key in ${TARGET_KEYS[@]+"${TARGET_KEYS[@]}"}; do
		build_target "${target_key}" || overall_status=1
	done
	for node in "${NODES_LIST[@]}"; do
		[ -n "${NODE_RESULT[${node}]:-}" ] && continue
		deploy_node "${node}" || overall_status=1
	done

	print_summary
	return "${overall_status}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	trap 'exit 130' INT
	trap 'exit 143' TERM
	main "$@"
fi
