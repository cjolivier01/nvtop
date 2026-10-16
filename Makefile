# MAKEFILE_LIST is a space-separated list, so a makefile whose path contains a
# space cannot recover its own directory from it. CURDIR is a single value and
# is always right for `make` from the source directory and for `make -C`; the
# check below turns `make -f /elsewhere/Makefile` from an unrelated directory
# into an error instead of a build of the wrong tree.
TOPDIR := $(CURDIR)
ifneq ($(shell test -f "$(TOPDIR)/CMakeLists.txt" && echo found),found)
$(error Run make from the nvtop source directory, or use `make -C /path/to/nvtop`)
endif
CMAKE ?= cmake
CTEST ?= ctest
PREFIX ?= /usr/local

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

.PHONY: all print_targets perf debug relwithdebinfo asan test run install uninstall clean distclean expunge

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
# sudo, and building as root would leave the build tree owned by root.
install:
	@if [ ! -f "$(RELEASE_DIR)/CMakeCache.txt" ]; then \
		echo 'ERROR: no Release build in $(RELEASE_DIR); run `make perf` first.' >&2; \
		exit 2; \
	fi
	$(CMAKE) --install "$(RELEASE_DIR)"

uninstall:
	@if [ ! -f "$(RELEASE_DIR)/install_manifest.txt" ]; then \
		echo 'ERROR: no install manifest in $(RELEASE_DIR); nothing was installed from this build tree.' >&2; \
		exit 2; \
	fi
	$(CMAKE) --build "$(RELEASE_DIR)" --target uninstall

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
	rm -rf "$(BUILD_ROOT)"

print_targets:
	@printf '%s\n' \
		"Available make targets (run 'make <target>'):" \
		'' \
		"'make -j N <target>' forwards N to CMake as --parallel N; with no -j," \
		'nvtop builds with --parallel $(NPROC). Override with CMAKE_JOBS=N.' \
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
		'install        Install an existing Release build under $(PREFIX) (honors DESTDIR).' \
		'               Run `make perf` first; this target does not build, so that' \
		'               `sudo make install` does not leave a root-owned build tree.' \
		'uninstall      Remove the files listed by the Release build install manifest.' \
		'' \
		'Tests' \
		'-----' \
		'test           Configure Debug with BUILD_TESTING=ON and run ctest (needs GTest).' \
		'' \
		'Maintenance & Cleanup' \
		'---------------------' \
		'clean          cmake --build --target clean in every configured build directory.' \
		'distclean      Remove $(BUILD_ROOT) entirely (also aliased as expunge).' \
		'expunge        Same as distclean.' \
		'' \
		'Meta' \
		'----' \
		'print_targets  Shows this help text.'
