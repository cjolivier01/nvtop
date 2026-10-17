# Builder image for nvtop Debian packages.
#
# The point of building in here rather than on the developer's machine is the
# ABI baseline: the binary links against the target release's glibc, ncurses,
# libdrm and libsystemd, and dpkg-shlibdeps derives the dependency versions
# from those rather than from whatever the build host happens to run.
ARG TARGET_UBUNTU=24.04
FROM ubuntu:${TARGET_UBUNTU}

ENV DEBIAN_FRONTEND=noninteractive

# Mirrors the dependency list in the README, plus dpkg-dev for the packaging
# itself and binutils (via build-essential) for the strip step.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      dpkg-dev \
      file \
      libdrm-dev \
      libncurses-dev \
      libsystemd-dev \
      libudev-dev \
      pkg-config \
    && rm -rf /var/lib/apt/lists/*

COPY build-deb.sh /usr/local/bin/build-deb
RUN chmod 0755 /usr/local/bin/build-deb

ENTRYPOINT ["/usr/local/bin/build-deb"]
