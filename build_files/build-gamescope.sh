#!/bin/bash
# Builds gamescope from bazzite-org/gamescope with our sticky-app-id patch
# applied, and stages the patched binary under $OUTPUT_DIR (which the final
# stage copies onto /).
#
# We avoid `dnf5 builddep gamescope` here because the bazzite RPM's SPEC
# pulls Fedora pipewire/sdl2-compat/wlroots -devel sets whose transitive
# *-libs are excluded by Bazzite (it ships its own builds). Instead we
# install only what gamescope's own meson.build needs and disable the
# optional features whose Fedora -devel packages would hit those excludes
# (pipewire, sdl2_backend). gamescope already vendors wlroots/libliftoff/
# vkroots via meson force_fallback, so we don't need system wlroots-devel.
#
# Pinned to a baNNN tag from bazzite-org/gamescope so we track the same
# version stream as the bazzite base image's RPM. Renovate watches this
# ref (see .github/renovate.json5) and opens a PR when a new ba* tag is
# published upstream; CI then tells us if our patch still applies.
set -ouex pipefail

CTX="/ctx"
BUILD_DIR="/tmp/gamescope-build"
OUTPUT_DIR="/output"
GAMESCOPE_REPO="https://github.com/bazzite-org/gamescope.git"
GAMESCOPE_REF="ba147"

### Build toolchain + gamescope's own meson deps. Subproject-resolved deps
### (wlroots, libliftoff, vkroots, libdisplay-info, openvr, stb, glm) are
### built from vendored sources during `meson setup`.
dnf5 install -y --skip-unavailable \
    git meson ninja-build gcc-c++ make pkgconf-pkg-config \
    libX11-devel libXdamage-devel libXcomposite-devel libXcursor-devel \
    libXrender-devel libXext-devel libXfixes-devel libXxf86vm-devel \
    libXtst-devel libXres-devel libXmu-devel libXi-devel \
    libxcb-devel xcb-util-wm-devel xcb-util-renderutil-devel \
    xcb-util-devel xcb-util-errors-devel \
    wayland-devel wayland-protocols-devel libxkbcommon-devel \
    libdecor-devel libdrm-devel libcap-devel \
    libavif-devel librsvg2-devel libliftoff-devel libdisplay-info-devel \
    vulkan-headers vulkan-loader-devel libeis-devel systemd-devel \
    hwdata-devel google-benchmark-devel \
    libinput-devel pixman-devel libseat-devel \
    luajit-devel \
    glslang-devel glslc

# Bazzite locks xorg-x11-server-Xwayland to its custom build via dnf5's
# versionlock (a built-in command, not a plugin), which makes Fedora's
# Xwayland uninstallable — the -devel package's strict version match against
# -runtime can't be resolved. wlroots needs pkgconfig(xwayland) at build time,
# so drop the lock just in this builder stage and pull Fedora's matching
# runtime + -devel. Builder is discarded, so the final image's Xwayland and
# versionlock state are untouched.
dnf5 versionlock delete xorg-x11-server-Xwayland
dnf5 install -y xorg-x11-server-Xwayland-devel

### Clone, pin, init submodules, apply patch.
rm -rf "${BUILD_DIR}"
git clone "${GAMESCOPE_REPO}" "${BUILD_DIR}"
cd "${BUILD_DIR}"
git checkout "${GAMESCOPE_REF}"
git submodule update --init --recursive

git apply --check "${CTX}/gamescope-sticky-app-id.patch"
git apply       "${CTX}/gamescope-sticky-app-id.patch"

### Build. pipewire and sdl2_backend disabled because their Fedora -devel
### packages depend on bazzite-excluded *-libs. The user runs gamescope
### only via scopebuddy (Wayland backend nested under GNOME), so neither
### feature is exercised.
###
### -Dwlroots:werror=false: the vendored wlroots 0.18 subproject ships
### werror=true and builds against Fedora's rolling libinput-devel. When
### Fedora adds a new LIBINPUT_SWITCH_* enum (e.g. LIBINPUT_SWITCH_KEYPAD_SLIDE),
### wlroots' unhandled switch case trips -Werror=switch and breaks the daily
### build. We don't control the pinned wlroots source, so disable werror for
### that subproject to stay robust against upstream header bumps.
meson setup build \
    --prefix=/usr --buildtype=release \
    -Dpipewire=disabled \
    -Dsdl2_backend=disabled \
    -Denable_openvr_support=false \
    -Dwlroots:werror=false

# Bazzite's PATH front-loads /usr/lib64/ccache symlinks, and ccache races on
# parallel writes in this builder ("File exists" on the cache dir). Bypass
# for this build — we're not benefitting from a warm cache here anyway.
CCACHE_DISABLE=1 meson compile -C build

### Stage just the gamescope binary. Other artifacts (libexec helpers,
### Vulkan WSI layer, scripts) we leave as the base RPM ships them to
### keep the override surface minimal and reduce divergence risk.
mkdir -p "${OUTPUT_DIR}/usr/bin"
install -Dm755 "${BUILD_DIR}/build/src/gamescope" "${OUTPUT_DIR}/usr/bin/gamescope"

### Sanity check.
"${OUTPUT_DIR}/usr/bin/gamescope" --help >/dev/null

echo "Patched gamescope staged at ${OUTPUT_DIR}/usr/bin/gamescope"
