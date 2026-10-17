# MAKEFILE_LIST is a space-separated list, so a makefile whose path contains a
# space cannot recover its own directory from it. CURDIR is a single value and
# is always right for `make` from the source directory and for `make -C`; the
# check below turns `make -f /elsewhere/Makefile` from an unrelated directory
# into an error instead of a build of the wrong tree.
# Two nvtop-specific paths, so that running this from some other CMake
# project's directory is an error rather than a build of that project.
TOPDIR := $(CURDIR)
ifneq ($(shell test -f "$(TOPDIR)/CMakeLists.txt" && test -f "$(TOPDIR)/src/nvtop.c" && echo found),found)
$(error Run make from the nvtop source directory, or use `make -C /path/to/nvtop`)
endif
CMAKE ?= cmake
CTEST ?= ctest
PREFIX ?= /usr/local

# Whether the caller actually asked for a prefix, as opposed to inheriting the
# default above. `sudo make install` drops PREFIX from the environment, so a
# plain install must use whatever `make perf` configured rather than complain.
PREFIX_IS_EXPLICIT := $(filter-out file default undefined,$(origin PREFIX))
# Handed to the install recipe through the environment rather than inlined
# into it, so that a quote in the value cannot break the shell parse.
export NVTOP_WANTED_PREFIX := $(PREFIX)

# Every build type gets its own directory under build/ so that, for example, a
# Release and an ASan tree can coexist without reconfiguring each other away.
BUILD_ROOT ?= $(TOPDIR)/build
RELEASE_DIR := $(BUILD_ROOT)/release
DEBUG_DIR := $(BUILD_ROOT)/debug
RELWITHDEBINFO_DIR := $(BUILD_ROOT)/relwithdebinfo
ASAN_DIR := $(BUILD_ROOT)/asan

# Forward `make -j N` to CMake as `--parallel N`. GNU make normalizes -jN/-j N
# into a single "-jN" word in MAKEFLAGS; a bare "-j" (unlimited) and a missing
# -j both fall back to nproc. Override directly with `make CMAKE_JOBS=16 ...`.
MAKE_JOBS_FLAG := $(firstword $(filter -j%,$(MAKEFLAGS)))
NPROC := $(shell nproc 2>/dev/null || echo 1)
CMAKE_JOBS ?= $(or $(patsubst -j%,%,$(MAKE_JOBS_FLAG)),$(NPROC))
CMAKE_PARALLEL_FLAG := --parallel $(strip $(CMAKE_JOBS))

# Extra `-D...` flags appended to every configure step, e.g.
# `make perf CMAKE_ARGS="-DNVIDIA_SUPPORT=ON -DAMDGPU_SUPPORT=OFF"`.
CMAKE_ARGS ?=
CMAKE_COMMON_ARGS = -DCMAKE_INSTALL_PREFIX="$(PREFIX)" $(CMAKE_ARGS)

# Debian packaging. PACKAGE_VERSION defaults to the version in CMakeLists.txt.
DEB_OUTPUT_DIR ?= $(TOPDIR)/dist
PACKAGE_VERSION ?=
MAKE_DEB_ARGS = --output-dir="$$NVTOP_DEB_OUTPUT_DIR" --jobs="$$NVTOP_JOBS" \
	$${NVTOP_PACKAGE_VERSION:+--version="$$NVTOP_PACKAGE_VERSION"}

# Containerized packaging and deployment. TARGET_UBUNTU picks the ABI baseline
# the package is built against; NODES is the comma-separated SSH node list.
TARGET_UBUNTU ?= 24.04
NODES ?=
DEPLOY_OUTPUT_DIR ?= $(DEB_OUTPUT_DIR)
export NVTOP_NODES := $(NODES)
export NVTOP_TARGET_UBUNTU := $(strip $(TARGET_UBUNTU))
export NVTOP_DEB_OUTPUT_DIR := $(DEB_OUTPUT_DIR)
export NVTOP_JOBS := $(strip $(CMAKE_JOBS))
export NVTOP_PACKAGE_VERSION := $(PACKAGE_VERSION)
export NVTOP_DEPLOY_OUTPUT_DIR := $(DEPLOY_OUTPUT_DIR)

# $(1) = build directory, $(2) = configure arguments specific to that directory
# MAKEFLAGS is cleared so that the make CMake drives does not warn about the
# jobserver it cannot join; parallelism is passed explicitly instead.
define cmake_build
	$(CMAKE) -S "$(TOPDIR)" -B "$(1)" $(2) $(CMAKE_COMMON_ARGS)
	MAKEFLAGS= $(CMAKE) --build "$(1)" $(CMAKE_PARALLEL_FLAG)
endef

all: print_targets

# debug and test share build/debug, so two of these must never run at once.
# Parallelism belongs to CMake here anyway, not to this makefile.
.NOTPARALLEL:

.PHONY: all print_targets perf debug relwithdebinfo asan test run install uninstall clean distclean expunge \
	deb deb-only deb-pin deb-docker deb-ubuntu22 deb-ubuntu24 deb-ubuntu26 deploy undeploy

perf:
	$(call cmake_build,$(RELEASE_DIR),-DCMAKE_BUILD_TYPE=Release)

debug:
	$(call cmake_build,$(DEBUG_DIR),-DCMAKE_BUILD_TYPE=Debug)

relwithdebinfo:
	$(call cmake_build,$(RELWITHDEBINFO_DIR),-DCMAKE_BUILD_TYPE=RelWithDebInfo)

asan:
	$(call cmake_build,$(ASAN_DIR),-DCMAKE_BUILD_TYPE=Debug -DSANITIZE_ADDRESS=On -DSANITIZE_UNDEFINED=On)

test:
	$(call cmake_build,$(DEBUG_DIR),-DCMAKE_BUILD_TYPE=Debug -DBUILD_TESTING=ON)
	cd "$(DEBUG_DIR)" && $(CTEST) --output-on-failure

run: perf
	"$(RELEASE_DIR)/src/nvtop"

# Deliberately not dependent on `perf`: this is the one target people run under
# sudo, and building as root would leave the build tree owned by root. The
# prefix is therefore whatever `make perf` configured, and PREFIX here can only
# be checked against it -- CMake bakes it into the RPATH at configure time, so
# redirecting the install alone would produce a subtly different binary.
install:
	@if [ ! -x "$(RELEASE_DIR)/src/nvtop" ]; then \
		echo 'ERROR: no Release build in $(RELEASE_DIR); run `make perf` first.' >&2; \
		exit 2; \
	fi
	@if [ -n "$(PREFIX_IS_EXPLICIT)" ]; then \
		strip_slashes() { printf '%s' "$$1" | sed -e 's|/*$$||'; }; \
		configured=$$(strip_slashes "$$(sed -n 's|^CMAKE_INSTALL_PREFIX:PATH=||p' "$(RELEASE_DIR)/CMakeCache.txt")"); \
		wanted=$$(strip_slashes "$$NVTOP_WANTED_PREFIX"); \
		if [ "$$configured" != "$$wanted" ]; then \
			echo "ERROR: $(RELEASE_DIR) was configured with prefix '$$configured', not '$$wanted'." >&2; \
			echo "       Install there with \`make install PREFIX=$$configured\`, or rebuild for" >&2; \
			echo "       '$$wanted' with \`make perf PREFIX=$$wanted\` and install again." >&2; \
			exit 2; \
		fi; \
	fi
	$(CMAKE) --install "$(RELEASE_DIR)"

# Removes exactly what this build tree installed, from the manifest CMake
# wrote, then prunes any directory the install left empty -- walking up to but
# never including the prefix itself, since nothing records whether the prefix
# pre-existed.
uninstall:
	@manifest="$(RELEASE_DIR)/install_manifest.txt"; \
	if [ ! -f "$$manifest" ]; then \
		echo "ERROR: no install manifest at $$manifest." >&2; \
		echo "       uninstall removes what this build tree installed, so run it from" >&2; \
		echo "       the tree the install came from, or \`make perf && make install\` again" >&2; \
		echo "       with the same PREFIX first." >&2; \
		exit 2; \
	fi; \
	configured=$$(sed -n 's|^CMAKE_INSTALL_PREFIX:PATH=||p' "$(RELEASE_DIR)/CMakeCache.txt" 2>/dev/null); \
	root="$(DESTDIR)$$configured"; \
	dirlist=$$(mktemp) || exit $$?; \
	: "CMake writes the manifest without a trailing newline, so the read loop" ; \
	: "below must also accept a final unterminated line or it drops a file." ; \
	trap 'rm -f "$$dirlist"' EXIT; \
	while IFS= read -r entry || [ -n "$$entry" ]; do \
		[ -n "$$entry" ] || continue; \
		path="$(DESTDIR)$$entry"; \
		if [ -e "$$path" ] || [ -L "$$path" ]; then \
			echo "  removing $$path"; \
			rm -f -- "$$path" || exit $$?; \
		else \
			echo "  already gone: $$path"; \
		fi; \
		dirname -- "$$path" >>"$$dirlist"; \
	done <"$$manifest"; \
	[ -n "$$configured" ] || exit 0; \
	sort -ru "$$dirlist" | while IFS= read -r dir; do \
		while [ -n "$$dir" ] && [ "$$dir" != "$$root" ] && [ "$$dir" != "/" ]; do \
			rmdir -- "$$dir" 2>/dev/null || break; \
			echo "  removed empty directory $$dir"; \
			dir=$$(dirname -- "$$dir"); \
		done; \
	done

deb:
	@echo "Debian package output directory: $(DEB_OUTPUT_DIR)"
	@"$(TOPDIR)/packaging/make_deb.sh" $(MAKE_DEB_ARGS)

deb-only:
	@"$(TOPDIR)/packaging/make_deb.sh" $(MAKE_DEB_ARGS) --deb-only

deb-pin:
	@"$(TOPDIR)/packaging/make_deb.sh" $(MAKE_DEB_ARGS) --pin-only

deb-docker:
	@"$(TOPDIR)/packaging/make_deb_docker.sh" \
		--target-ubuntu="$$NVTOP_TARGET_UBUNTU" \
		--output-dir="$$NVTOP_DEB_OUTPUT_DIR/ubuntu$$NVTOP_TARGET_UBUNTU" \
		--jobs="$$NVTOP_JOBS" \
		$${NVTOP_PACKAGE_VERSION:+--version="$$NVTOP_PACKAGE_VERSION"}

deb-ubuntu22:
	$(MAKE) deb-docker TARGET_UBUNTU=22.04

deb-ubuntu24:
	$(MAKE) deb-docker TARGET_UBUNTU=24.04

deb-ubuntu26:
	$(MAKE) deb-docker TARGET_UBUNTU=26.04

deploy:
	@if [ -z "$$(printf '%s' "$$NVTOP_NODES" | tr -d '[:space:]')" ]; then \
		echo 'ERROR: NODES is required. Usage: make deploy NODES=node1,node2' >&2; \
		exit 2; \
	fi
	@NODES="$$NVTOP_NODES" \
	PACKAGE_VERSION="$$NVTOP_PACKAGE_VERSION" \
	DEPLOY_OUTPUT_DIR="$$NVTOP_DEPLOY_OUTPUT_DIR" \
	DEPLOY_JOBS="$$NVTOP_JOBS" \
	"$(TOPDIR)/packaging/deploy.sh"

undeploy:
	@if [ -z "$$(printf '%s' "$$NVTOP_NODES" | tr -d '[:space:]')" ]; then \
		echo 'ERROR: NODES is required. Usage: make undeploy NODES=node1,node2' >&2; \
		exit 2; \
	fi
	@NODES="$$NVTOP_NODES" "$(TOPDIR)/packaging/deploy.sh" --undeploy

clean:
	@cleaned=0; \
	for dir in "$(BUILD_ROOT)" "$(BUILD_ROOT)"/*/; do \
		[ -f "$$dir/CMakeCache.txt" ] || continue; \
		echo "Cleaning $$dir"; \
		$(CMAKE) --build "$$dir" --target clean || exit $$?; \
		cleaned=1; \
	done; \
	[ "$$cleaned" = 1 ] || echo "Nothing to clean: no configured build directory under $(BUILD_ROOT)."

distclean expunge:
	@rm -rf "$(BUILD_ROOT)" "$$NVTOP_DEB_OUTPUT_DIR"

print_targets:
	@printf '%s\n' \
		"Available make targets (run 'make <target>'):" \
		'' \
		"'make -j N <target>' forwards N to CMake as --parallel N; with no -j," \
		'nvtop builds with --parallel $(NPROC). Override with CMAKE_JOBS=N.' \
		'Targets themselves run one at a time: debug and test share a build directory.' \
		'Append configure flags with CMAKE_ARGS="-DNVIDIA_SUPPORT=ON ...".' \
		'' \
		'Build Outputs' \
		'-------------' \
		'perf           Release build, no debug info (build/release).' \
		'debug          Debug build with the extra warning flags (build/debug).' \
		'relwithdebinfo Optimized build with debug info (build/relwithdebinfo).' \
		'asan           Debug build with the address and undefined sanitizers (build/asan).' \
		'' \
		'Run & Install' \
		'-------------' \
		'run            Build Release and run build/release/src/nvtop.' \
		'install        Install an existing Release build (honors DESTDIR).' \
		'               Run `make perf` first; this target does not build, so that' \
		'               `sudo make install` does not leave a root-owned build tree.' \
		'               The prefix is whatever `make perf PREFIX=...` configured.' \
		'uninstall      Remove the files this build tree installed, per its install' \
		'               manifest, and any directory left empty (never the prefix).' \
		'' \
		'Packaging' \
		'---------' \
		'deb            Build the nvtop and nvtop-pin .deb files into $(DEB_OUTPUT_DIR).' \
		'deb-only       Build only the nvtop .deb.' \
		'deb-pin        Build only the nvtop-pin .deb (apt pin, no compilation).' \
		'deb-docker     Build the .deb files in an Ubuntu $(TARGET_UBUNTU) container, so the' \
		'               binary matches that release rather than this machine.' \
		'deb-ubuntu22   deb-docker for Ubuntu 22.04 (also -ubuntu24, -ubuntu26).' \
		'               Containerized packages land in $(DEB_OUTPUT_DIR)/ubuntu<release>.' \
		'' \
		'Deployment' \
		'----------' \
		'deploy         Build and install on comma-separated NODES over SSH (required).' \
		'               One package per distinct Ubuntu release in the set.' \
		'undeploy       Purge nvtop and nvtop-pin from comma-separated NODES.' \
		'               Purges any nvtop, including a distribution-installed one.' \
		'' \
		'Tests' \
		'-----' \
		'test           Configure Debug with BUILD_TESTING=ON and run ctest (needs GTest).' \
		'' \
		'Maintenance & Cleanup' \
		'---------------------' \
		'clean          cmake --build --target clean in every configured build directory.' \
		'distclean      Remove $(BUILD_ROOT) and $(DEB_OUTPUT_DIR) (also aliased as expunge).' \
		'expunge        Same as distclean.' \
		'' \
		'Meta' \
		'----' \
		'print_targets  Shows this help text.'
