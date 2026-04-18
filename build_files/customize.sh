#!/bin/bash
set -ouex pipefail

CTX="/ctx"
VARIANT="${VARIANT:-default}"

echo "Running customize.sh for VARIANT=${VARIANT}"

### Common: ghostty as default terminal ###

# Ensure ghostty is installed. It's not in Fedora 43 base repos, so we use the
# pgdev/ghostty COPR. That package ships /usr/share/terminfo/g/ghostty which
# conflicts with ncurses-term; we download the transaction and install via
# `rpm -Uvh --replacefiles` to claim the file for ghostty while keeping
# ncurses-term otherwise intact.
if ! rpm -q ghostty >/dev/null 2>&1; then
    dnf5 -y copr enable pgdev/ghostty
    mkdir -p /tmp/ghostty-rpms
    # Use `dnf5 download` with .x86_64 suffix so dnf doesn't also pull the
    # matching .src.rpm (which drags in build-deps via --resolve).
    dnf5 download --resolve --destdir=/tmp/ghostty-rpms ghostty.x86_64
    # Install only the binary RPMs with --replacefiles so ghostty can claim
    # /usr/share/terminfo/g/ghostty over ncurses-term.
    rpm -Uvh --replacefiles --replacepkgs \
        $(find /tmp/ghostty-rpms -maxdepth 1 -name '*.rpm' ! -name '*.src.rpm')
    rm -rf /tmp/ghostty-rpms
    dnf5 -y copr disable pgdev/ghostty
fi

install -Dm644 "${CTX}/config/ghostty-terminal.sh" /etc/profile.d/ghostty-terminal.sh
install -Dm644 "${CTX}/config/mimeapps.list"       /etc/xdg/mimeapps.list

# GNOME's 'org.gnome.desktop.default-applications.terminal' key for apps that
# still read it (Nautilus "Open in Terminal", etc.).
mkdir -p /etc/dconf/db/distro.d
cat >/etc/dconf/db/distro.d/10-ghostty-terminal <<'EOF'
[org/gnome/desktop/applications/terminal]
exec='ghostty'
exec-arg=''
EOF
dconf update || true

### Niri variant ###

if [[ "${VARIANT}" == "niri" ]]; then
    COPR_REPOS=(
        avengemedia/dms
        ulysg/xwayland-satellite
        yalter/niri
    )
    for repo in "${COPR_REPOS[@]}"; do
        dnf5 -y copr enable "${repo}" || echo "warn: copr ${repo} unavailable"
    done

    dnf5 install -y --setopt=install_weak_deps=False \
        niri \
        dms \
        dgop \
        dsearch \
        matugen \
        cava \
        cliphist \
        wl-clipboard \
        xdg-desktop-portal-gtk \
        xwayland-satellite \
        greetd \
        dms-greeter \
        adobe-source-code-pro-fonts \
        fontawesome-fonts-all

    # Strip GNOME shell/session/settings stack. Keep gnome-keyring,
    # xdg-desktop-portal-gnome, nautilus, and other GTK bits intact.
    dnf5 remove -y \
        gnome-shell \
        gnome-session \
        gnome-control-center \
        gnome-settings-daemon \
        gnome-software \
        gdm || true

    # bazzite ships unowned .desktop session files for GNOME Wayland/Xorg and
    # gamescope/Steam (not via rpm, so dnf can't remove them). Strip so the
    # greeter's session picker shows only niri. gamescope stays installed as a
    # package; we're just hiding the session entries.
    rm -f /usr/share/wayland-sessions/gnome*.desktop \
          /usr/share/xsessions/gnome*.desktop \
          /usr/share/wayland-sessions/gamescope*.desktop

    for repo in "${COPR_REPOS[@]}"; do
        dnf5 -y copr disable "${repo}" || true
    done

    install -Dm644 "${CTX}/config/greetd.toml" /etc/greetd/config.toml
    install -Dm644 "${CTX}/config/sysusers-dms-greeter.conf" /usr/lib/sysusers.d/dms-greeter.conf
    install -Dm644 "${CTX}/config/greetd-no-console.conf" \
        /etc/systemd/system/greetd.service.d/no-console.conf
    systemctl enable greetd.service
    systemctl set-default graphical.target

    # Auto-start DMS inside every user's niri session. The dms.service user
    # unit is WantedBy=graphical-session.target, which niri.service binds to
    # via niri-session; enabling --global adds it to every user's wants.
    systemctl --global enable dms.service
fi

echo "customize.sh done."
