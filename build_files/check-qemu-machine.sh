#!/bin/bash
set -ouex pipefail

# Guard the QEMU machine type the server's macOS VM depends on.
#
# The server booting this image hosts a macOS VM (libvirt domain `macOS-Sequoia`)
# that runs BlueBubbles. Changing the VM's QEMU machine type rewrites the guest's
# ACPI/SMBIOS tables, which changes the hardware fingerprint Apple sees and
# silently invalidates the Apple ID sign-in. The breakage is delayed: the account
# stays signed in until the auth token needs refreshing, so the logout surfaces
# ~8 days after the image update and looks unrelated.
#
# That already happened once: Fedora 44's QEMU 10.2.2 dropped every pc-q35-*
# below 5.0, the domain had to move off pc-q35-4.2, and the VM lost its Apple
# account a week later. Fail the build instead of discovering it in production.
#
# pc-q35-5.0 is already deprecated in QEMU 10.2, so this guard will fire on
# purpose eventually. That is the point: a planned migration, not a surprise.

REQUIRED_MACHINE="pc-q35-5.0"
QEMU="qemu-system-x86_64"

# qemu-system-x86-core comes from the upstream Bazzite base, not a layered
# package. If it vanishes, the server can't run the VM at all -- also fatal.
if ! command -v "${QEMU}" >/dev/null 2>&1; then
    echo "FATAL: ${QEMU} not found in the image; the macOS VM host needs qemu-system-x86-core" >&2
    exit 1
fi

if ! "${QEMU}" -machine help | grep -qE "^${REQUIRED_MACHINE//./\\.} "; then
    QEMU_VERSION=$(rpm -q --qf '%{VERSION}-%{RELEASE}' qemu-system-x86-core 2>/dev/null || echo unknown)
    echo "FATAL: ${REQUIRED_MACHINE} gone from qemu ${QEMU_VERSION}; macOS VM will lose its Apple ID" >&2
    echo "Pick a surviving machine type, update the macOS-Sequoia domain XML, and expect a re-auth." >&2
    "${QEMU}" -machine help | grep '^pc-q35-' >&2 || true
    exit 1
fi

echo "QEMU machine type guard OK: ${REQUIRED_MACHINE} still available."
