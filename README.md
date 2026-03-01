# bazzite-mt7927

Bazzite OCI image with MT7927 WiFi support.

## Status

WiFi works. Bluetooth does not.

## What this is

The kernel module patches come from [jetm/mediatek-mt7927-dkms](https://github.com/jetm/mediatek-mt7927-dkms) (included as a git submodule). This repo just packages them into a Bazzite OCI image built on top of `bazzite-nvidia-open:stable`.

## Installation

```bash
sudo bootc switch ghcr.io/samutoljamo/bazzite-mt7927:latest
```

Reboot after switching.

## Building / Testing locally

```bash
just build
just test
```
