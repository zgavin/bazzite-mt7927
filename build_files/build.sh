#!/bin/bash
set -ouex pipefail

CTX="/ctx"
BUILD_DIR="/tmp/mt7927-build"
OUTPUT_DIR="/output"

### Kernel version detection
KVER=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' | tail -1)
echo "Building MT7927 modules for kernel: ${KVER}"

### What we build
#
# MT7927 WiFi (PCIe ID 14c3:7927) and MT6639 Bluetooth are both in mainline
# since 7.2 / 7.1, so there is no "upstream already has it" early exit: the
# stock kernel claims the device either way. We still build the mt76 WiFi
# modules, which carry the AP-mode patches and the mlo_pm_work CVE backports
# that 7.2 lacks, and we still ship the MT6639 BT firmware, which linux-firmware
# does not carry -- without it btmtk resets the controller in an unbounded loop.
#
# btusb/btmtk come from the stock kernel, matching the DKMS package's default on
# 7.1+; our copies would add only the 0489:e156 ID. WiFi firmware also comes
# from linux-firmware, which has MediaTek's newer build; installing the blob we
# extract from the Windows driver ZIP would shadow it.

### Install build dependencies
dnf5 install -y --skip-unavailable \
    gcc make "kernel-devel-${KVER}" kernel-headers python3 curl patch xz unzip

### Prepare sources using submodule Makefile
mkdir -p "${BUILD_DIR}"
DKMS="${BUILD_DIR}/dkms"
cp -r "${CTX}/mediatek-mt7927-dkms" "${DKMS}"

### Fetch sources with retries
#
# `make download` pulls the 151MB kernel tarball and the ASUS driver ZIP with a
# bare `curl -L -f`, so one mid-stream reset fails the whole image build (seen
# in CI as `curl: (92) HTTP/2 stream 1 was not closed cleanly: PROTOCOL_ERROR`
# two thirds through the kernel tarball). Both the Makefile and
# download-driver.sh skip a file that already exists, so fetch them here with
# retries and checksum verification, and `make download` then no-ops.
PKGBUILD="${DKMS}/PKGBUILD"
MT76_KVER=$(sed -n "s/^_mt76_kver='\(.*\)'/\1/p" "${PKGBUILD}")
KERNEL_TARBALL="linux-${MT76_KVER}.tar.xz"
KERNEL_SHA256=$(sed -n "s/^sha256sums=('\([0-9a-f]\{64\}\)'.*/\1/p" "${PKGBUILD}")
DRIVER_ZIP=$(sed -n "s/^_driver_filename='\(.*\)'/\1/p" "${PKGBUILD}")
DRIVER_SHA256=$(sed -n "s/^_driver_sha256='\([0-9a-f]\{64\}\)'/\1/p" "${PKGBUILD}")

# Fail fast rather than burning five attempts on an unverifiable download if the
# submodule ever reformats these declarations.
for var in MT76_KVER KERNEL_SHA256 DRIVER_ZIP DRIVER_SHA256; do
    if [[ -z "${!var}" ]]; then
        echo >&2 "ERROR: could not parse ${var} from ${PKGBUILD}"
        exit 1
    fi
done

retry() {
    local what="$1"; shift
    local attempt
    for attempt in 1 2 3 4 5; do
        if "$@"; then
            return 0
        fi
        if [[ ${attempt} -lt 5 ]]; then
            echo "warn: ${what} failed (attempt ${attempt}/5), retrying in $((attempt * 10))s"
            sleep $((attempt * 10))
        fi
    done
    echo >&2 "ERROR: ${what} failed after 5 attempts"
    return 1
}

# Keeps a partial file so the next attempt resumes it, but discards a complete
# file that fails verification -- resuming that would never converge.
verify_or_discard() {
    local file="$1" sha256="$2"
    if echo "${sha256}  ${file}" | sha256sum --check --status; then
        return 0
    fi
    echo "warn: $(basename "${file}") failed sha256 verification, discarding"
    rm -f "${file}"
    return 1
}

fetch_kernel_tarball() {
    # --continue-at resumes a partial file from a previous attempt; the speed
    # limit aborts a transfer that has stalled instead of waiting out the
    # runner's job timeout.
    curl -L -f --continue-at - \
        --retry 3 --retry-delay 5 --retry-all-errors \
        --connect-timeout 30 --speed-limit 1000 --speed-time 60 \
        -o "${DKMS}/${KERNEL_TARBALL}" \
        "https://cdn.kernel.org/pub/linux/kernel/v${MT76_KVER%%.*}.x/${KERNEL_TARBALL}" \
        || return 1
    verify_or_discard "${DKMS}/${KERNEL_TARBALL}" "${KERNEL_SHA256}"
}

fetch_driver_zip() {
    # Each attempt re-runs the script so it mints a fresh CloudFront token;
    # reusing an expired signed URL would just 403.
    DRIVER_FILENAME="${DRIVER_ZIP}" "${DKMS}/download-driver.sh" "${DKMS}" || return 1
    verify_or_discard "${DKMS}/${DRIVER_ZIP}" "${DRIVER_SHA256}"
}

retry "kernel tarball download" fetch_kernel_tarball
retry "driver ZIP download" fetch_driver_zip

make -C "${DKMS}" download
make -C "${DKMS}" sources

SRCDIR="${DKMS}/_build"

### Compile
KSRC="/lib/modules/${KVER}/build"
make -C "${KSRC}" M="${SRCDIR}/mt76" -j"$(nproc)" modules

### Stage kernel modules
INSTALL_DIR="${OUTPUT_DIR}/usr/lib/modules/${KVER}/extra/mt7927"
mkdir -p "${INSTALL_DIR}"
install -m644 "${SRCDIR}"/mt76/{mt76,mt76-connac-lib,mt792x-lib}.ko "${INSTALL_DIR}/"
install -m644 "${SRCDIR}"/mt76/mt7921/{mt7921-common,mt7921e}.ko    "${INSTALL_DIR}/"
install -m644 "${SRCDIR}"/mt76/mt7925/{mt7925-common,mt7925e}.ko    "${INSTALL_DIR}/"
xz --check=crc32 -f "${INSTALL_DIR}"/*.ko

### Stage firmware
install -Dm644 "${SRCDIR}/firmware/BT_RAM_CODE_MT6639_2_1_hdr.bin" \
    "${OUTPUT_DIR}/usr/lib/firmware/mediatek/mt7927/BT_RAM_CODE_MT6639_2_1_hdr.bin"

### Stage config files
install -Dm644 "${CTX}/config/depmod-mt7927.conf" "${OUTPUT_DIR}/etc/depmod.d/mt7927.conf"
mkdir -p "${OUTPUT_DIR}/etc/modules-load.d"
echo "mt7925e" > "${OUTPUT_DIR}/etc/modules-load.d/mt7925e.conf"

echo "MT7927 driver build complete."
