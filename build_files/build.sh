#!/bin/bash
# Build and install MediaTek MT7927 (WiFi 7 + Bluetooth) kernel modules.
#
# Sources mt76 + btusb from the Linux 6.19.4 kernel tarball, applies patches
# from the bundled mediatek-mt7927-dkms submodule, compiles against the
# kernel headers present in the image, and installs the resulting .ko files
# plus firmware blobs extracted from the ASUS CDN driver ZIP.
#
# Compat fix applied for kernel < 6.19:
#   kzalloc_flex() (introduced in 6.19) is replaced with kzalloc(struct_size())
#   in agg-rx.c before compilation.

set -ouex pipefail

### --------------------------------------------------------------------------
### Configuration
### --------------------------------------------------------------------------

# Linux kernel version the mt76 source and patches target
MT76_KVER="6.19.4"

# ASUS driver ZIP (contains mtkwlan.dat with firmware blobs).
# If the CDN token API breaks, replace this with a direct URL or pre-cached copy.
DRIVER_FILENAME="DRV_WiFi_MTK_MT7925_MT7927_TP_W11_64_V5603998_20250709R.zip"
DRIVER_SHA256="b377fffa28208bb1671a0eb219c84c62fba4cd6f92161b74e4b0909476307cc8"

SUBMODULE_DIR="/ctx/mediatek-mt7927-dkms"
BUILD_DIR="/tmp/mt7927-build"

### --------------------------------------------------------------------------
### Kernel version detection
### --------------------------------------------------------------------------

KVER=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' | tail -1)
echo "Building MT7927 modules for kernel: ${KVER}"

### --------------------------------------------------------------------------
### Install build-time dependencies
### --------------------------------------------------------------------------

dnf5 install -y --skip-unavailable \
    gcc \
    make \
    "kernel-devel-${KVER}" \
    kernel-headers \
    python3 \
    curl \
    patch \
    xz

### --------------------------------------------------------------------------
### Download and extract kernel source (mt76 + btusb subtrees only)
### --------------------------------------------------------------------------

mkdir -p "${BUILD_DIR}"

TARBALL="${BUILD_DIR}/linux-${MT76_KVER}.tar.xz"
echo "Downloading Linux ${MT76_KVER} kernel tarball..."
curl -L --fail --retry 3 \
    "https://cdn.kernel.org/pub/linux/kernel/v${MT76_KVER%%.*}.x/linux-${MT76_KVER}.tar.xz" \
    -o "${TARBALL}"

echo "Extracting mt76 WiFi source..."
mkdir -p "${BUILD_DIR}/mt76"
tar -xf "${TARBALL}" \
    --strip-components=6 \
    -C "${BUILD_DIR}/mt76" \
    "linux-${MT76_KVER}/drivers/net/wireless/mediatek/mt76"

echo "Extracting bluetooth source..."
mkdir -p "${BUILD_DIR}/bluetooth"
tar -xf "${TARBALL}" \
    --strip-components=3 \
    -C "${BUILD_DIR}/bluetooth" \
    "linux-${MT76_KVER}/drivers/bluetooth"

rm -f "${TARBALL}"

### --------------------------------------------------------------------------
### Apply patches from the submodule
### --------------------------------------------------------------------------

echo "Applying MT7902 WiFi patch..."
patch -d "${BUILD_DIR}/mt76" -p1 < "${SUBMODULE_DIR}/mt7902-wifi-6.19.patch"

echo "Applying MT6639 WiFi init patch..."
patch -d "${BUILD_DIR}/mt76" -p1 < "${SUBMODULE_DIR}/mt6639-wifi-init.patch"

echo "Applying MT6639 WiFi DMA patch..."
patch -d "${BUILD_DIR}/mt76" -p1 < "${SUBMODULE_DIR}/mt6639-wifi-dma.patch"

echo "Applying MT6639 Bluetooth patch..."
patch -d "${BUILD_DIR}/bluetooth" -p3 < "${SUBMODULE_DIR}/mt6639-bt-6.19.patch"

### --------------------------------------------------------------------------
### Kernel compat fixes (6.19 source on 6.17 headers)
### --------------------------------------------------------------------------

# linux/soc/airoha/airoha_offload.h was introduced in 6.19 for Airoha NPU/PPE
# offload support.  The 6.17 kernel-headers package does not ship it.
# Inject a minimal stub directly into the kernel headers tree so that the
# standard #include <linux/soc/airoha/airoha_offload.h> resolves without any
# extra compiler flags.
AIROHA_STUB_DIR="/usr/src/kernels/${KVER}/include/linux/soc/airoha"
mkdir -p "${AIROHA_STUB_DIR}"
cat > "${AIROHA_STUB_DIR}/airoha_offload.h" <<'AIROHA_EOF'
/* SPDX-License-Identifier: GPL-2.0-only */
/* Compat stub: verbatim copy of linux/soc/airoha/airoha_offload.h from
 * Linux 6.19, included here because kernel-devel for 6.17 does not ship it.
 * CONFIG_NET_AIROHA and CONFIG_NET_AIROHA_NPU are both unset on x86/Fedora,
 * so only the no-op #else branches are compiled.
 */
#ifndef AIROHA_OFFLOAD_H
#define AIROHA_OFFLOAD_H

#include <linux/skbuff.h>
#include <linux/spinlock.h>
#include <linux/workqueue.h>

enum {
	PPE_CPU_REASON_HIT_UNBIND_RATE_REACHED = 0x0f,
};

struct airoha_ppe_dev {
	struct {
		int (*setup_tc_block_cb)(struct airoha_ppe_dev *dev,
					 void *type_data);
		void (*check_skb)(struct airoha_ppe_dev *dev,
				  struct sk_buff *skb, u16 hash,
				  bool rx_wlan);
	} ops;

	void *priv;
};

static inline struct airoha_ppe_dev *airoha_ppe_get_dev(struct device *dev)
{ return NULL; }
static inline void airoha_ppe_put_dev(struct airoha_ppe_dev *dev) {}
static inline int airoha_ppe_dev_setup_tc_block_cb(struct airoha_ppe_dev *dev,
						   void *type_data)
{ return -EOPNOTSUPP; }
static inline void airoha_ppe_dev_check_skb(struct airoha_ppe_dev *dev,
					    struct sk_buff *skb, u16 hash,
					    bool rx_wlan) {}

#define NPU_NUM_CORES		8
#define NPU_NUM_IRQ		6
#define NPU_RX0_DESC_NUM	512
#define NPU_RX1_DESC_NUM	512

/* CTRL */
#define NPU_RX_DMA_DESC_LAST_MASK	BIT(27)
#define NPU_RX_DMA_DESC_LEN_MASK	GENMASK(26, 14)
#define NPU_RX_DMA_DESC_CUR_LEN_MASK	GENMASK(13, 1)
#define NPU_RX_DMA_DESC_DONE_MASK	BIT(0)
/* INFO */
#define NPU_RX_DMA_PKT_COUNT_MASK	GENMASK(31, 29)
#define NPU_RX_DMA_PKT_ID_MASK		GENMASK(28, 26)
#define NPU_RX_DMA_SRC_PORT_MASK	GENMASK(25, 21)
#define NPU_RX_DMA_CRSN_MASK		GENMASK(20, 16)
#define NPU_RX_DMA_FOE_ID_MASK		GENMASK(15, 0)
/* DATA */
#define NPU_RX_DMA_SID_MASK		GENMASK(31, 16)
#define NPU_RX_DMA_FRAG_TYPE_MASK	GENMASK(15, 14)
#define NPU_RX_DMA_PRIORITY_MASK	GENMASK(13, 10)
#define NPU_RX_DMA_RADIO_ID_MASK	GENMASK(9, 6)
#define NPU_RX_DMA_VAP_ID_MASK		GENMASK(5, 2)
#define NPU_RX_DMA_FRAME_TYPE_MASK	GENMASK(1, 0)

struct airoha_npu_rx_dma_desc {
	u32 ctrl;
	u32 info;
	u32 data;
	u32 addr;
	u64 rsv;
} __packed;

/* CTRL */
#define NPU_TX_DMA_DESC_SCHED_MASK	BIT(31)
#define NPU_TX_DMA_DESC_LEN_MASK	GENMASK(30, 18)
#define NPU_TX_DMA_DESC_VEND_LEN_MASK	GENMASK(17, 1)
#define NPU_TX_DMA_DESC_DONE_MASK	BIT(0)

#define NPU_TXWI_LEN	192

struct airoha_npu_tx_dma_desc {
	u32 ctrl;
	u32 addr;
	u64 rsv;
	u8 txwi[NPU_TXWI_LEN];
} __packed;

enum airoha_npu_wlan_set_cmd {
	WLAN_FUNC_SET_WAIT_PCIE_ADDR,
	WLAN_FUNC_SET_WAIT_DESC,
	WLAN_FUNC_SET_WAIT_NPU_INIT_DONE,
	WLAN_FUNC_SET_WAIT_TRAN_TO_CPU,
	WLAN_FUNC_SET_WAIT_BA_WIN_SIZE,
	WLAN_FUNC_SET_WAIT_DRIVER_MODEL,
	WLAN_FUNC_SET_WAIT_DEL_STA,
	WLAN_FUNC_SET_WAIT_DRAM_BA_NODE_ADDR,
	WLAN_FUNC_SET_WAIT_PKT_BUF_ADDR,
	WLAN_FUNC_SET_WAIT_IS_TEST_NOBA,
	WLAN_FUNC_SET_WAIT_FLUSHONE_TIMEOUT,
	WLAN_FUNC_SET_WAIT_FLUSHALL_TIMEOUT,
	WLAN_FUNC_SET_WAIT_IS_FORCE_TO_CPU,
	WLAN_FUNC_SET_WAIT_PCIE_STATE,
	WLAN_FUNC_SET_WAIT_PCIE_PORT_TYPE,
	WLAN_FUNC_SET_WAIT_ERROR_RETRY_TIMES,
	WLAN_FUNC_SET_WAIT_BAR_INFO,
	WLAN_FUNC_SET_WAIT_FAST_FLAG,
	WLAN_FUNC_SET_WAIT_NPU_BAND0_ONCPU,
	WLAN_FUNC_SET_WAIT_TX_RING_PCIE_ADDR,
	WLAN_FUNC_SET_WAIT_TX_DESC_HW_BASE,
	WLAN_FUNC_SET_WAIT_TX_BUF_SPACE_HW_BASE,
	WLAN_FUNC_SET_WAIT_RX_RING_FOR_TXDONE_HW_BASE,
	WLAN_FUNC_SET_WAIT_TX_PKT_BUF_ADDR,
	WLAN_FUNC_SET_WAIT_INODE_TXRX_REG_ADDR,
	WLAN_FUNC_SET_WAIT_INODE_DEBUG_FLAG,
	WLAN_FUNC_SET_WAIT_INODE_HW_CFG_INFO,
	WLAN_FUNC_SET_WAIT_INODE_STOP_ACTION,
	WLAN_FUNC_SET_WAIT_INODE_PCIE_SWAP,
	WLAN_FUNC_SET_WAIT_RATELIMIT_CTRL,
	WLAN_FUNC_SET_WAIT_HWNAT_INIT,
	WLAN_FUNC_SET_WAIT_ARHT_CHIP_INFO,
	WLAN_FUNC_SET_WAIT_TX_BUF_CHECK_ADDR,
	WLAN_FUNC_SET_WAIT_TOKEN_ID_SIZE,
};

enum airoha_npu_wlan_get_cmd {
	WLAN_FUNC_GET_WAIT_NPU_INFO,
	WLAN_FUNC_GET_WAIT_LAST_RATE,
	WLAN_FUNC_GET_WAIT_COUNTER,
	WLAN_FUNC_GET_WAIT_DBG_COUNTER,
	WLAN_FUNC_GET_WAIT_RXDESC_BASE,
	WLAN_FUNC_GET_WAIT_WCID_DBG_COUNTER,
	WLAN_FUNC_GET_WAIT_DMA_ADDR,
	WLAN_FUNC_GET_WAIT_RING_SIZE,
	WLAN_FUNC_GET_WAIT_NPU_SUPPORT_MAP,
	WLAN_FUNC_GET_WAIT_MDC_LOCK_ADDRESS,
	WLAN_FUNC_GET_WAIT_NPU_VERSION,
};

struct airoha_npu {
	/* empty on non-Airoha kernels */
};

static inline struct airoha_npu *airoha_npu_get(struct device *dev)
{ return NULL; }
static inline void airoha_npu_put(struct airoha_npu *npu) {}
static inline int airoha_npu_wlan_init_reserved_memory(struct airoha_npu *npu)
{ return -EOPNOTSUPP; }
static inline int airoha_npu_wlan_send_msg(struct airoha_npu *npu,
					   int ifindex,
					   enum airoha_npu_wlan_set_cmd cmd,
					   void *data, int data_len, gfp_t gfp)
{ return -EOPNOTSUPP; }
static inline int airoha_npu_wlan_get_msg(struct airoha_npu *npu, int ifindex,
					  enum airoha_npu_wlan_get_cmd cmd,
					  void *data, int data_len, gfp_t gfp)
{ return -EOPNOTSUPP; }
static inline u32 airoha_npu_wlan_get_queue_addr(struct airoha_npu *npu,
						 int qid, bool xmit)
{ return 0; }
static inline void airoha_npu_wlan_set_irq_status(struct airoha_npu *npu,
						  u32 val) {}
static inline u32 airoha_npu_wlan_get_irq_status(struct airoha_npu *npu, int q)
{ return 0; }
static inline void airoha_npu_wlan_enable_irq(struct airoha_npu *npu, int q) {}
static inline void airoha_npu_wlan_disable_irq(struct airoha_npu *npu, int q) {}

#endif /* AIROHA_OFFLOAD_H */
AIROHA_EOF

# kzalloc_flex() was introduced in kernel 6.19; replace with the equivalent
# kzalloc(struct_size()) call that works on 6.17 and earlier.
RUNNING_KVER_MAJOR=$(echo "${KVER}" | cut -d. -f1)
RUNNING_KVER_MINOR=$(echo "${KVER}" | cut -d. -f2)

if [[ "${RUNNING_KVER_MAJOR}" -lt 6 ]] || \
   { [[ "${RUNNING_KVER_MAJOR}" -eq 6 ]] && [[ "${RUNNING_KVER_MINOR}" -lt 19 ]]; }; then
    echo "Applying kzalloc_flex compat fix for kernel ${KVER}..."
    sed -i \
        's/kzalloc_flex(\*tid, reorder_buf, size)/kzalloc(struct_size(tid, reorder_buf, size), GFP_ATOMIC)/g' \
        "${BUILD_DIR}/mt76/agg-rx.c"
fi

### --------------------------------------------------------------------------
### Create Kbuild files for out-of-tree build
### --------------------------------------------------------------------------

cat > "${BUILD_DIR}/mt76/Kbuild" <<'EOF'
obj-m += mt76.o
obj-m += mt76-connac-lib.o
obj-m += mt792x-lib.o
obj-m += mt7921/
obj-m += mt7925/

mt76-y := \
	mmio.o util.o trace.o dma.o mac80211.o debugfs.o eeprom.o \
	tx.o agg-rx.o mcu.o wed.o scan.o channel.o pci.o

mt76-connac-lib-y := mt76_connac_mcu.o mt76_connac_mac.o mt76_connac3_mac.o

mt792x-lib-y := mt792x_core.o mt792x_mac.o mt792x_trace.o \
		mt792x_debugfs.o mt792x_dma.o mt792x_acpi_sar.o

CFLAGS_trace.o := -I$(src)
CFLAGS_mt792x_trace.o := -I$(src)
EOF

cat > "${BUILD_DIR}/mt76/mt7921/Kbuild" <<'EOF'
obj-m += mt7921-common.o
obj-m += mt7921e.o

mt7921-common-y := mac.o mcu.o main.o init.o debugfs.o
mt7921e-y := pci.o pci_mac.o pci_mcu.o
EOF

cat > "${BUILD_DIR}/mt76/mt7925/Kbuild" <<'EOF'
obj-m += mt7925-common.o
obj-m += mt7925e.o

mt7925-common-y := mac.o mcu.o regd.o main.o init.o debugfs.o
mt7925e-y := pci.o pci_mac.o pci_mcu.o
EOF

### --------------------------------------------------------------------------
### Compile modules
### --------------------------------------------------------------------------

KSRC="/lib/modules/${KVER}/build"

echo "Compiling Bluetooth modules..."
make -C "${KSRC}" M="${BUILD_DIR}/bluetooth" -j$(nproc) modules

echo "Compiling WiFi modules..."
make -C "${KSRC}" M="${BUILD_DIR}/mt76" -j$(nproc) modules

### --------------------------------------------------------------------------
### Install .ko files
### --------------------------------------------------------------------------

INSTALL_DIR="/usr/lib/modules/${KVER}/extra/mt7927"
mkdir -p "${INSTALL_DIR}"

echo "Installing kernel modules to ${INSTALL_DIR}..."

# Bluetooth
install -m644 "${BUILD_DIR}/bluetooth/btusb.ko"  "${INSTALL_DIR}/"
install -m644 "${BUILD_DIR}/bluetooth/btmtk.ko"  "${INSTALL_DIR}/"

# WiFi core
install -m644 "${BUILD_DIR}/mt76/mt76.ko"                   "${INSTALL_DIR}/"
install -m644 "${BUILD_DIR}/mt76/mt76-connac-lib.ko"        "${INSTALL_DIR}/"
install -m644 "${BUILD_DIR}/mt76/mt792x-lib.ko"             "${INSTALL_DIR}/"

# MT7921 (MT7902 support)
install -m644 "${BUILD_DIR}/mt76/mt7921/mt7921-common.ko"   "${INSTALL_DIR}/"
install -m644 "${BUILD_DIR}/mt76/mt7921/mt7921e.ko"         "${INSTALL_DIR}/"

# MT7925 / MT7927
install -m644 "${BUILD_DIR}/mt76/mt7925/mt7925-common.ko"   "${INSTALL_DIR}/"
install -m644 "${BUILD_DIR}/mt76/mt7925/mt7925e.ko"         "${INSTALL_DIR}/"

# Compress all installed modules
xz -f "${INSTALL_DIR}"/*.ko

### --------------------------------------------------------------------------
### Download ASUS driver ZIP and extract firmware
### --------------------------------------------------------------------------

echo "Fetching ASUS CDN download token..."
TOKEN_URL="https://cdnta.asus.com/api/v1/TokenHQ?filePath=https:%2F%2Fdlcdnta.asus.com%2Fpub%2FASUS%2Fmb%2F08WIRELESS%2F${DRIVER_FILENAME}%3Fmodel%3DROG%2520CROSSHAIR%2520X870E%2520HERO&systemCode=rog"

JSON=$(curl -sf "${TOKEN_URL}" -X POST -H 'Origin: https://rog.asus.com')
if [[ -z "${JSON}" ]]; then
    echo "ERROR: Failed to retrieve ASUS CDN token" >&2
    exit 1
fi

EXPIRES=${JSON#*\"expires\":\"}; EXPIRES=${EXPIRES%%\"*}
SIGNATURE=${JSON#*\"signature\":\"}; SIGNATURE=${SIGNATURE%%\"*}
KEY_PAIR_ID=${JSON#*\"keyPairId\":\"}; KEY_PAIR_ID=${KEY_PAIR_ID%%\"*}

DRIVER_ZIP="${BUILD_DIR}/${DRIVER_FILENAME}"
DOWNLOAD_URL="https://dlcdnta.asus.com/pub/ASUS/mb/08WIRELESS/${DRIVER_FILENAME}?model=ROG%20CROSSHAIR%20X870E%20HERO&Signature=${SIGNATURE}&Expires=${EXPIRES}&Key-Pair-Id=${KEY_PAIR_ID}"

echo "Downloading ASUS driver ZIP..."
curl -L --fail --retry 3 "${DOWNLOAD_URL}" -o "${DRIVER_ZIP}"

echo "Verifying driver ZIP checksum..."
echo "${DRIVER_SHA256}  ${DRIVER_ZIP}" | sha256sum -c -

echo "Extracting mtkwlan.dat from ZIP..."
python3 -c "import zipfile, sys; zipfile.ZipFile(sys.argv[1]).extract('mtkwlan.dat', sys.argv[2])" \
    "${DRIVER_ZIP}" "${BUILD_DIR}"

echo "Extracting firmware blobs..."
python3 "${SUBMODULE_DIR}/extract_firmware.py" \
    "${BUILD_DIR}/mtkwlan.dat" \
    "${BUILD_DIR}/firmware"

### --------------------------------------------------------------------------
### Install firmware blobs
### --------------------------------------------------------------------------

echo "Installing firmware..."

install -Dm644 \
    "${BUILD_DIR}/firmware/BT_RAM_CODE_MT6639_2_1_hdr.bin" \
    "/usr/lib/firmware/mediatek/mt6639/BT_RAM_CODE_MT6639_2_1_hdr.bin"

install -Dm644 \
    "${BUILD_DIR}/firmware/WIFI_MT6639_PATCH_MCU_2_1_hdr.bin" \
    "/usr/lib/firmware/mediatek/mt7927/WIFI_MT6639_PATCH_MCU_2_1_hdr.bin"

install -Dm644 \
    "${BUILD_DIR}/firmware/WIFI_RAM_CODE_MT6639_2_1.bin" \
    "/usr/lib/firmware/mediatek/mt7927/WIFI_RAM_CODE_MT6639_2_1.bin"

### --------------------------------------------------------------------------
### Force patched modules to be preferred over stock kernel modules
###
### modules.alias is built from the stock kernel tree during rpm install and
### does NOT include our extra/mt7927/ overrides.  Even after depmod the
### stock btusb/mt7925e entries can win because depmod ordering is
### alphabetical and "kernel/" sorts before "extra/".  Install directives
### in modprobe.d guarantee our patched copies are always used regardless
### of depmod ordering or initramfs regeneration by the base image.
### --------------------------------------------------------------------------

MODPROBE_CONF="/etc/modprobe.d/mt7927-override.conf"
cat > "${MODPROBE_CONF}" <<'MODPROBE_EOF'
# Force the patched MediaTek MT7927 modules from extra/mt7927/ to be loaded
# instead of the stock kernel modules.  This is necessary because depmod
# may regenerate modules.alias from the stock kernel tree after our build
# step, causing the unpatched btusb/mt7925e to be loaded instead.

install btusb /sbin/modprobe --ignore-install btusb "$@"; /sbin/modprobe btmtk
install mt7925e /sbin/modprobe --ignore-install mt7925e "$@"
MODPROBE_EOF

# Ensure the extra modules directory is in the module search path so that
# "modprobe btusb" resolves to extra/mt7927/btusb.ko.xz (higher priority
# than kernel/drivers/bluetooth/btusb.ko.xz).
# /etc/depmod.d/mt7927.conf overrides the default search order so that
# "extra" is checked before "updates" and "kernel".
mkdir -p /etc/depmod.d
cat > /etc/depmod.d/mt7927.conf <<'DEPMOD_EOF'
# Ensure out-of-tree mt7927 modules in extra/ override stock kernel modules.
# Directories listed first have higher priority.
search extra updates built-in weak-updates override
DEPMOD_EOF

### --------------------------------------------------------------------------
### Update module dependency map and rebuild initramfs
### --------------------------------------------------------------------------

echo "Running depmod..."
depmod -a "${KVER}"

# Dracut is intentionally skipped here.  Running dracut inside a container
# build fails: the overlay filesystem does not support xattrs, /boot/efi is
# not mounted, and hostonly mode tries to introspect a system that doesn't
# exist yet.  Bootc/rpm-ostree regenerates the initramfs from the installed
# modules on first boot, so baking one into the image layer is unnecessary.

### --------------------------------------------------------------------------
### Auto-load configuration
### --------------------------------------------------------------------------

echo "mt7925e" > /etc/modules-load.d/mt7925e.conf

### --------------------------------------------------------------------------
### Cleanup
### --------------------------------------------------------------------------

echo "Cleaning up build artifacts..."
rm -rf "${BUILD_DIR}"

dnf5 remove -y \
    "kernel-devel-${KVER}" \
    kernel-headers \
    libarchive \
    patch || true   # non-fatal: some may be pulled in by other image deps

echo "MT7927 driver build complete."
