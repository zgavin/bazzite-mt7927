# bazzite-mt7927

Custom Bazzite DX OCI images with MT7927 WiFi 7 / MT6639 Bluetooth support. Updated daily.

## Status

WiFi and Bluetooth work. See the [upstream driver status](https://github.com/jetm/mediatek-mt7927-dkms#status) for details.

## What this is

Kernel module patches come from [jetm/mediatek-mt7927-dkms](https://github.com/jetm/mediatek-mt7927-dkms) (included as a git submodule). This repo packages them into two bazzite-dx images, published at `ghcr.io/zgavin/`.

Both images ship with **ghostty as the default terminal** (`x-scheme-handler/terminal`, `$TERMINAL`, and the GNOME terminal-exec key all point at ghostty).

## Available images

| Image | Base | Desktop | Extras |
|---|---|---|---|
| `bazzite-dx-gnome-mt7927` | bazzite-dx-gnome | GNOME | mt7927 driver, ghostty default |
| `bazzite-dx-niri-mt7927` | bazzite-dx-gnome | niri + Dank Material Shell | mt7927 driver, ghostty default, greetd + tuigreet, GNOME shell/session/gdm removed |

The niri variant starts from `bazzite-dx-gnome` so it still has GTK, gnome-keyring, xdg-desktop-portal-gnome, and Nautilus — just not the GNOME shell/session/control-center/settings-daemon/software stack or GDM. Login is handled by greetd+tuigreet on tty1.

Only `:stable` is published; the upstream `bazzite-dx-gnome:testing` tag doesn't exist, so no testing channel is built.

## Installation

```bash
# GNOME (default bazzite-dx-gnome + mt7927)
sudo bootc switch ghcr.io/zgavin/bazzite-dx-gnome-mt7927:stable

# niri + Dank Material Shell (GNOME stripped)
sudo bootc switch ghcr.io/zgavin/bazzite-dx-niri-mt7927:stable
```

Reboot after switching.

## Building / testing locally

```bash
# Default GNOME variant
just build bazzite-dx-gnome-mt7927 stable ghcr.io/ublue-os/bazzite-dx-gnome:stable

# niri variant (pass VARIANT=niri as a build arg)
podman build \
  --build-arg BASE_IMAGE=ghcr.io/ublue-os/bazzite-dx-gnome:stable \
  --build-arg VARIANT=niri \
  -t bazzite-dx-niri-mt7927:stable .

# Test either image
just test bazzite-dx-gnome-mt7927 stable
just test bazzite-dx-niri-mt7927 stable
```
