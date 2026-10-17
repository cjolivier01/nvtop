NVTOP
=====

What is NVTOP?
--------------

NVTOP stands for Neat Videocard TOP, a (h)top like task monitor for GPUs and
accelerators. It can handle multiple GPUs and print information about them in a
htop-familiar way.

Currently supported vendors are AMD (Linux amdgpu driver), Apple (limited M1 &
M2 support), Huawei (Ascend), Intel (Linux i915/Xe drivers), NVIDIA (Linux
proprietary divers), Qualcomm Adreno (Linux MSM driver), Broadcom VideoCore (Linux v3d driver),
Rockchip, MetaX (MXSML driver), Enflame (Linux EFML driver).

Because a picture is worth a thousand words:

![NVTOP interface](/screenshot/NVTOP_ex1.png)

Table of Contents
-----------------

- [NVTOP Options and Interactive Commands](#nvtop-options-and-interactive-commands)
  - [Interactive Setup Window](#interactive-setup-window)
  - [Saving Preferences](#saving-preferences)
  - [NVTOP Manual and Command line Options](#nvtop-manual-and-command-line-options)
- [GPU Support](#gpu-support)
  - [AMD](#amd)
  - [Intel](#intel)
  - [NVIDIA](#nvidia)
  - [Adreno](#adreno)
  - [Apple](#apple)
  - [Ascend](#ascend) (only tested on 910B)
  - [VideoCore](#videocore)
  - [Rockchip](#rockchip)
  - [MetaX](#metax)
  - [Enflame](#enflame)
- [Build](#build)
- [Distribution Specific Installation Process](#distribution-specific-installation-process)
  - [Ubuntu / Debian](#ubuntu--debian)
    - [Ubuntu Impish (21.10) / Debian buster (stable) and more recent (stable)](#ubuntu-impish-2110-debian-buster-stable-and-more-recent)
  - [Fedora / Red Hat / CentOS](#fedora--red-hat--centos)
  - [OpenSUSE](#opensuse)
  - [Arch Linux](#arch-linux)
  - [Gentoo](#gentoo)
  - [AppImage](#appimage)
  - [Snap](#snap)
  - [Conda-forge](#conda-forge)
  - [Docker](#docker)
- [NVTOP Build](#nvtop-build)
- [Troubleshoot](#troubleshoot)
- [License](#license)

NVTOP Options and Interactive Commands
--------------------------------------
### Interactive Setup Window

NVTOP has a builtin setup utility that provides a way to specialize the interface to your needs.
Simply press ``F2`` and select the options that are the best for you.

![NVTOP Setup Window](/screenshot/Nvtop-config.png)

### Saving Preferences

You can save the preferences set in the setup window by pressing ``F12``.
The preferences will be loaded the next time you run ``nvtop``.

### NVTOP Manual and Command line Options

NVTOP comes with a manpage!
```bash
man nvtop
```
For quick command line arguments help
```bash
nvtop -h
nvtop --help
```

GPU Support
-----------

### AMD

NVTOP supports AMD GPUs using the `amdgpu` driver through the exposed DRM and
sysfs interface.

AMD introduced the fdinfo interface in kernel 5.14 ([browse kernel
source](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/drivers/gpu/drm/amd/amdgpu/amdgpu_fdinfo.c?h=linux-5.14.y)).
Hence, you will need a kernel with a version greater or equal to 5.14 to see the
processes using AMD GPUs.

Support for recent GPUs are regularly mainlined into the linux kernel, so please
use a recent-enough kernel for your GPU.

### Intel

NVTOP supports Intel GPUs using the `i915` or `xe` linux driver.

Intel introduced the fdinfo interface in kernel 5.19 ([browse kernel
source](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/drivers/gpu/drm/i915/i915_drm_client.c?h=linux-5.19.y)).
Hence, you will need a kernel with a version greater or equal to 5.19 to see the
processes using Intel GPUs.

Intel requires CAP_PERFMON or CAP_SYS_ADMIN capabilities to access the total memory usage,
you can run `sudo setcap cap_perfmon=ep nvtop` to grant the necessary permissions or run nvtop as root.

### NVIDIA

The *NVML library* does not support some of the queries for GPUs coming before the
Kepler microarchitecture. Anything starting at GeForce 600, GeForce 800M and
successor should work fine. For more information about supported GPUs please
take a look at the [NVML documentation](http://docs.nvidia.com/deploy/nvml-api/nvml-api-reference.html#nvml-api-reference).

**SM occupancy** is the share of the theoretical maximum number of warps that
was resident on the SMs — the same figure DCGM reports as
`DCGM_FI_PROF_SM_OCCUPANCY`. It answers something the GPU utilization rate
cannot: that one only says a kernel was resident, not how much of the machine
it filled, so a workload can sit at 100% GPU with 13% occupancy.

It appears as an `SM[...]` meter on the utilization line next to GPU and MEM,
and as a chart series. Both are **on by default** for NVIDIA GPUs where the
driver reports the counters exist, and both are turned off together from the
*Chart* section of the setup window (F2), per GPU. nvtop samples the counters
only on GPUs that have the metric enabled, so switching it off stops the
sampling too — as does `-p`, which disables the charts and the meter with
them.

The number comes from the NVML GPM API, added in the R520 driver series.
Support is queried per GPU at startup via `nvmlGpmQueryDeviceSupport`, so a
GPU without the counters is simply not offered the metric rather than being
given a meter reading `N/A` and a chart line pinned at zero. If you enable it
by hand on such a GPU, that is what you get.

The meter needs enough room on the device row to sit beside GPU, MEM and the
encoder/decoder meters without squeezing the memory meter below its own text,
and is dropped when there is not. Note that row is sized from the longest GPU
name, not from your terminal, so widening the terminal will not bring the
meter back on a machine where it is absent.

Charts are a separate budget: nvtop fits as many as the terminal has room for
and merges or drops the rest, so on a small terminal with several GPUs a chart
can disappear — an integrated GPU's goes first. Fewer metrics per GPU means
more charts fit, which is one reason to switch SM occupancy off if you are
short of space.

### Adreno

NVTOP supports Adreno GPUs using the `msm` linux driver.

msm introduced the fdinfo interface in kernel 6.0 ([browse kernel
source](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/drivers/gpu/drm/msm/msm_drv.c?h=linux-6.0.y)).
Hence, you will need a kernel with a version greater or equal to 6.0 to see the
processes using Adreno GPUs.

### Apple

NVTOP includes some initial support for Apple using Metal. This is only supported when building for Apple, and when building for Apple only this vendor is supported.

**APPLE SUPPORT STATUS**
- Apple support is still being worked on. Some bugs and limitations may apply.

### Ascend

NVTOP supports Ascend (testing on Altas 800 (910B)) by DCMI API (version 6.0.0).

Currently, the DCMI only supports limited APIs, missing PCIe generation, tx/rx throughput info, max power draw etc.

### VideoCore

NVTOP supports VideoCore (testing on raspberrypi 4B).

Supports GPU frequency, temperature, utilization, per-process utilization, GPU memory usage, and H264 decoding utilization.

On non-raspberry pi os, you need to use the `linux-rpi 6.12.y` kernel and above, and ensure the presence of the `/dev/vcio` device.

### Rockchip

NVTOP supports Rockchip (testing on orangepi 5 plus).

Supports NPU frequency, temperature, utilization.

### MetaX

NVTOP supports MetaX (testing on MXC500) by MXSML LIBRARY.

For more information about GPUs please take a look at the [METAX documentation](https://developer.metax-tech.com/doc/index)

### Enflame

NVTOP supports Enflame GCUs (testing on Enflame S60, Enflame L300 and Enflame L600) by EFML LIBRARY

GCU, which refers to General Compute Unit, is a type of accelerator card that is used to perform general-purpose computing tasks just like GPGPU.

Build
-----

Several libraries are required in order for NVTOP to display GPU info:

* The *ncurses* library driving the user interface.
  * This makes the screen look beautiful.
* For NVIDIA: the *NVIDIA Management Library* (*NVML*) which comes with the GPU driver.
  * This queries the GPU for info.
* For AMD: the libdrm library used to query AMD GPUs through the kernel driver.
* For METAX: the *MetaX System Management Library* (*MXSML*) which comes with the GPU driver.
  * This queries the GPU for info.
* For Enflame: the *Enflame Management Library* (*EFML*) which comes with the GCU driver.

## Distribution Specific Installation Process

### Ubuntu / Debian

If your distribution provides the snap utility, follow the [snap installation process](#snap) to obtain an up-to-date version of `nvtop`.

A standalone application is available as [AppImage](#appimage).

#### Ubuntu Focal (20.04), Debian buster (stable) and more recent

```bash
sudo apt install nvtop
```

#### Ubuntu PPA

A [PPA supporting Ubuntu 20.04 and newer](https://launchpad.net/~quentiumyt/+archive/ubuntu/nvtop) is provided by
[Quentin Lienhardt](https://github.com/QuentiumYT) that offers an up-to-date version of `nvtop`, enabled for NVIDIA, AMD and Intel.

```bash
sudo add-apt-repository ppa:quentiumyt/nvtop
sudo apt install nvtop
```

#### Older

- AMD and Intel Dependencies
  ```bash
  sudo apt install libdrm-dev libsystemd-dev
  # Ubuntu 18.04
  sudo apt install libudev-dev
  ```

- NVIDIA Dependency
  - NVIDIA drivers (see [Ubuntu Wiki](https://help.ubuntu.com/community/BinaryDriverHowto/Nvidia) or [Ubuntu PPA](https://launchpad.net/~graphics-drivers/+archive/ubuntu/ppa) or [Debian Wiki](https://wiki.debian.org/NvidiaGraphicsDrivers#NVIDIA_Proprietary_Driver))

- NVTOP Dependencies
  - CMake, ncurses and Git
  ```bash
  sudo apt install cmake libncurses5-dev libncursesw5-dev git
  ```

- NVTOP
  - Follow the [NVTOP Build](#nvtop-build)


### Fedora / Red Hat / CentOS

A standalone application is available as [AppImage](#appimage).

#### Fedora 36 and newer

- ```bash
  sudo dnf install nvtop
  ```

#### Red Hat Enterprise Linux 8 and 9

- ```bash
  sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %{rhel}).noarch.rpm
  sudo dnf install nvtop
  ```

#### CentOS Stream, Rocky Linux, AlmaLinux

- ```bash
  sudo dnf install -y epel-release
  sudo dnf install nvtop
  ```

#### Build process for Fedora / Red Hat / CentOS:

- AMD and Intel Dependencies
  ```bash
  sudo dnf install libdrm-devel systemd-devel
  ```

- NVIDIA Dependency
  - NVIDIA drivers, **CUDA required for nvml libraries** (see [RPM Fusion](https://rpmfusion.org/Howto/NVIDIA))

- NVTOP Dependencies
  - CMake, ncurses, C++ and Git
  ```bash
  sudo dnf install cmake ncurses-devel git gcc-c++
  ```

- NVTOP
  - Follow the [NVTOP Build](#nvtop-build)

### OpenSUSE

A standalone application is available as an [AppImage](#appimage).

Build process for OpenSUSE:

- AMD Dependency
  ```bash
  sudo zypper install libdrm-devel
  ```

- NVIDIA Dependency
  - NVIDIA drivers (see [SUSE Support Database](https://en.opensuse.org/SDB:NVIDIA_drivers))

- NVTOP Dependencies
  - CMake, ncurses and Git
    ```bash
    sudo zypper install cmake ncurses-devel git
    ```

- NVTOP
  - Follow the [NVTOP Build](#nvtop-build)

### Arch Linux

- ```bash
  sudo pacman -S nvtop
  ```

### Gentoo

- ```bash
  sudo emerge -av nvtop
  ```

### AppImage

An AppImage is a standalone application. Just download the AppImage, make it executable and run it!

- Go to the [release page](https://github.com/Syllo/nvtop/releases/latest) and download `nvtop-x86_64.AppImage`

- ```bash
  # Go to the download location ** The path may differ on your system **
  cd $HOME/Downloads
  # Make the AppImage executable
  chmod u+x nvtop-x86_64.AppImage
  # Enjoy nvtop
  ./nvtop-x86_64.AppImage
  ```

If you are curious how that works, please visit the [AppImage website](https://appimage.org/).

### Snap

- ```bash
  snap install nvtop
  # Add the capability to kill processes inside nvtop
  snap connect nvtop:process-control
  # Add the capability to inspect GPU information (fan, PCIe, power, etc)
  snap connect nvtop:hardware-observe
  # AMDGPU process list support (read /proc/<pid>)
  snap connect nvtop:system-observe
  # Temporary workaround to get per-process GPU usage (read /proc/<pid>/fdinfo)
  snap connect nvtop:kubernetes-support
  ```

Notice: The connect commands allow

### Conda-forge

A [conda-forge feedstock for `nvtop`](https://github.com/conda-forge/nvtop-feedstock) is available.

#### conda / mamba / miniforge

```bash
conda install --channel conda-forge nvtop
```

#### pixi

```bash
pixi global install nvtop
```

### Docker

- NVIDIA drivers (same as above)

- [nvidia-docker](https://github.com/NVIDIA/nvidia-docker) (See [Container Toolkit Installation Guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html#docker))

- ```bash
  git clone https://github.com/Syllo/nvtop.git && cd nvtop
  sudo docker build --tag nvtop .
  sudo docker run -it --rm --runtime=nvidia --gpus=all --pid=host nvtop
  ```

## NVTOP Build

```bash
git clone https://github.com/Syllo/nvtop.git
mkdir -p nvtop/build && cd nvtop/build
cmake .. -DNVIDIA_SUPPORT=ON -DAMDGPU_SUPPORT=ON -DINTEL_SUPPORT=ON
make

# Install globally on the system
sudo make install

# Alternatively, install without privileges at a location of your choosing
# cmake .. -DNVIDIA_SUPPORT=ON -DAMDGPU_SUPPORT=ON -DINTEL_SUPPORT=ON -DCMAKE_INSTALL_PREFIX=/path/to/your/dir
# make
# make install
```

If you use **conda** as environment manager and encounter an error while building NVTOP, try `conda deactivate` before invoking `cmake`.

The build system supports multiple build types (e.g. -DCMAKE_BUILD_TYPE=RelWithDebInfo):

* Release: Binary without debug info
* RelWithDebInfo: Binary with debug info
* Debug: Compile with warning flags and address/undefined sanitizers enabled (for development purposes)

### Top level Makefile

The repository root ships a `Makefile` that wraps the CMake invocations above,
so each build type lands in its own directory under `build/` and the trees do
not reconfigure each other away:

```bash
make              # List every target with a short description
make perf         # Release build in build/release
make debug        # Debug build (extra warning flags) in build/debug
make asan         # Debug build with the address/undefined sanitizers
make test         # Configure with BUILD_TESTING=ON and run ctest
make run          # Build Release and run it
make perf && sudo make install  # Install (DESTDIR is honored)
make distclean    # Remove build/ and dist/ entirely
```

`install` deliberately does not build: compiling under `sudo` would leave the
build tree owned by root and break the next unprivileged `make perf`. The
install prefix therefore belongs to the configure step — use
`make perf PREFIX=/opt/nvtop && sudo make install`. Passing a `PREFIX` to
`install` that disagrees with the one the tree was built for is refused rather
than silently installing somewhere else.

`make -j N <target>` is forwarded to CMake as `--parallel N`; extra configure
flags go through `CMAKE_ARGS`, for example
`make perf CMAKE_ARGS="-DNVIDIA_SUPPORT=ON -DAMDGPU_SUPPORT=OFF"`.

### Building a Debian package

`make deb` builds two packages into `dist/` (needs `dpkg-dev`):

* `nvtop_<version>_<arch>.deb` — the same shape as the package in the Ubuntu
  archive: same package name, section, priority and description, a stripped
  binary with a compressed man page, and a `postinst` that applies
  `setcap cap_perfmon=ep`. The library dependencies are derived with
  `dpkg-shlibdeps` from the binary that was actually built, so they match the
  feature flags you compiled with.
* `nvtop-pin_<version>_all.deb` — installs
  `/etc/apt/preferences.d/99-nvtop-local.pref`, which gives every *repository*
  version of `nvtop` a negative priority. With it installed, `apt upgrade` and
  `apt full-upgrade` leave your locally built nvtop alone instead of replacing
  it with the distribution's. The flip side is that `apt install nvtop` then
  has nothing to install either. The pin file is a conffile, so
  `apt-get purge nvtop-pin` drops the pin — plain `remove` leaves it behind.

```bash
make deb                              # both packages
make deb-only                         # just nvtop
make deb-pin                          # just the apt pin (no compilation)
make deb PACKAGE_VERSION=3.3.2-2      # override the version
```

The script prints the exact `dpkg -i` line to install what it just built;
`dist/` is not cleared between runs, so a glob can match several versions.

`packaging/make_deb.sh` can also be run directly; `--help` lists its options,
and anything after `--` is passed to the CMake configure step. Setting
`SOURCE_DATE_EPOCH` makes repeated builds of the same tree byte-identical.

The local package is versioned `3.3.2-1`, which outranks what the archive
ships today — but `-1` is the lowest plausible Debian revision, so any future
`3.3.2-2` or `3.3.2-1ubuntu1` would win. That is what `nvtop-pin` is for.
`nvtop-pin` deliberately writes to `/etc/apt/preferences.d`, which lintian
flags as `package-installs-apt-preferences`; it is meant for local use, not
for upload to an archive.

### Building against another Ubuntu release

`make deb` produces a package for the machine that ran it: `dpkg-shlibdeps`
reads the dependency versions off the binary it was handed. Built here on
26.04 the package declares `libc6 (>= 2.38)`, which installs on 24.04 but is
*uninstallable* on 22.04, whose glibc is 2.35. `make deb-docker` builds inside
a container of the target release instead, so the ABI baseline matches the
machine the package is for — the same source in a 22.04 container declares
`libc6 (>= 2.34)` and installs there.

```bash
make deb-docker                   # the TARGET_UBUNTU default, 24.04
make deb-ubuntu22                 # or -ubuntu24, -ubuntu26
make deb-docker TARGET_UBUNTU=26.04
```

Packages land in `dist/ubuntu<release>/`. Needs Docker. The container is fed
`git archive HEAD`, never the working tree, so the package corresponds to a
commit — the build refuses to run with tracked modifications.

### Deploying to other machines

`make deploy NODES=...` detects each node over SSH, builds one package per
distinct Ubuntu release in the set, uploads it, and installs it with apt so
the dependencies resolve:

```bash
make deploy   NODES=workstation,lab-01,lab-02
make undeploy NODES=workstation,lab-01,lab-02
```

Nodes need non-interactive SSH and passwordless `sudo`, and must be Ubuntu
22.04, 24.04 or 26.04 (or a derivative, matched on `UBUNTU_CODENAME`) on the
same architecture as the build host — the containers build natively, so
cross-architecture nodes are reported as unsupported rather than attempted. A
node that is unreachable or unsupported fails on its own; the others still
deploy, and the run ends with a per-node summary table.

`nvtop-pin` is installed in the same apt transaction as `nvtop`, so the
deployed build is not replaced by the distribution's on the next upgrade. Set
`DEPLOY_PIN=0` to skip it.

**`undeploy` purges any `nvtop`, not just one this tool installed.** It does
not check where the installed package came from, so running it on a node that
had the distribution's `nvtop` leaves that node with no `nvtop` at all —
deploy followed by undeploy is not a round trip. It purges rather than removes
so that the pin file in `/etc/apt/preferences.d` goes away with it.

Deployed packages are versioned `<project>-1+git<epoch>.<hash>`, so
redeploying a later commit registers as an upgrade and the summary tells you
which build each node is running. That suffix outranks `3.3.2-1`, and the
`-1ubuntu1` / `-1build1` forms, but **not** a `3.3.2-2`: if the archive ever
ships a higher Debian revision of the same upstream version it wins, which is
what `nvtop-pin` is there to prevent.

Other knobs:

| Variable | Effect |
| --- | --- |
| `PACKAGE_VERSION` | Override the derived version |
| `DEPLOY_OUTPUT_DIR` | Package output root (default: `dist`) |
| `DEPLOY_PIN=0` | Do not install `nvtop-pin` |
| `DEB_MAINTAINER` | Maintainer in the package; defaults to your git identity, which ends up in the control file and changelog on every node |
| `NVTOP_DEPLOY_SSH_OPTS` | Extra ssh/scp options, e.g. `-J bastion` or `-i ~/.ssh/lab`. Use `-o Port=N` rather than `-p`, which means different things to ssh and scp. These are appended after the built-in options, and ssh takes the first value per keyword, so they cannot override `BatchMode` or `ConnectTimeout` |
| `NVTOP_DEPLOY_SSH_CONNECT_TIMEOUT` | SSH connect timeout in seconds (default: 10) |

Deploy builds from `git archive HEAD` and refuses to run with tracked
modifications, so commit or stash first.

Troubleshoot
------------

- The plot looks bad:
  - Verify that you installed the wide character version of the ncurses library (libncurses**w**5-dev for Debian / Ubuntu), clean the build directory and restart the build process.
- **Putty**: Tell putty not to lie about its capabilities (`$TERM`) by setting the field ``Terminal-type string`` to ``putty`` in the menu
  ``Connection > Data > Terminal Details``.

License
-------

NVTOP is licensed under the GPLv3 license or any later version.
You will find a copy of the license inside the COPYING file of the repository or
at the GNU website <[www.gnu.org/licenses/](http://www.gnu.org/licenses/)>.
