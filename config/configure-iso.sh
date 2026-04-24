#!/usr/bin/env bash

set -exo pipefail

source /etc/os-release

# Import Terra keys
    echo "RakuOS overlay sync: importing Terra GPG keys for Fedora ${fedora_version}..."
    rpm --import "https://repos.fyralabs.com/terra${VERSION_ID}/key.asc"
    rpm --import "https://repos.fyralabs.com/terra${VERSION_ID}-mesa/key.asc"
    rpm --import "https://repos.fyralabs.com/terra${VERSION_ID}-multimedia/key.asc"
    #rpm --import "https://repos.fyralabs.com/terra${VERSION_ID}-nvidia/key.asc"

# Disable overlay services in live enviroment
systemctl disable --now rakuos-overlay-sync.service \
          rakuos-overlay-setup.service

# sudo requires drop-in files to be owned by root and not be writable by others
chown root:root /etc/sudoers.d/rakuos-software
chmod 0440 /etc/sudoers.d/rakuos-software

# add flatpak
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak update --system --appstream -y

# Remove all versionlocks, in order to avoid dependency issues
dnf -qy versionlock clear

# Install Anaconda
dnf install -qy --enable-repo=fedora-cisco-openh264 --allowerasing anaconda-live libblockdev-{btrfs,lvm,dm}

mkdir -p /var/lib/rpm-state # Needed for Anaconda Web UI

    # Read packages into array
    mapfile -t PACKAGES < <(
        grep -v '^\s*#' "/usr/share/rakuos/packages-live.list" \
        | grep -v '^\s*$' \
        | sed 's/\s*#.*//' \
        | tr -s ' \t' '\n' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | grep -v '^$'
    ) || true

dnf install -y --refresh "${PACKAGES[@]}"

# Utilities for displaying a dialog prompting users to review secure boot documentation
dnf install -qy --setopt=install_weak_deps=0 qrencode yad

# The installed image already carries the real prebaked overlay state.
# For the live squashfs, wipe that state back out so the live environment stays
# simple and does not try to carry a prebaked installed-system overlay around.
echo "Resetting RakuOS overlay state for live ISO..."
rm -rf /var/lib/rakuos
mkdir -p /var/lib/rakuos
if [[ -f /usr/share/rakuos/packages-live.list ]]; then
    cp /usr/share/rakuos/packages-live.list /var/lib/rakuos/packages.list
    sed -i -e '$a\' /var/lib/rakuos/packages.list
fi

# Variables
imageref="$(podman images --format '{{ index .Names 0 }}\n' 'rakuos*' | head -1)"
imageref="${imageref##*://}"
imageref="${imageref%%:*}"
imagetag="$(podman images --format '{{ .Tag }}\n' "$imageref" | head -1)"

# Rakuos anaconda profile
: ${VARIANT_ID:?}

echo "Rakuos release $VERSION_ID ($VERSION_CODENAME)" >/etc/system-release

# Get Artwork
git clone --depth 1 --quiet https://gitlab.com/rakuos/iso/iso-base.git /root/packages

# Installer icon
_icon=/root/packages/installer/branding/rakuos-installer.svg
_icon_symbol=/root/packages/installer/branding/rakuos-installer-symbolic.svg
if [[ -f $_icon ]]; then
    for f in \
        /usr/share/icons/hicolor/48x48/apps/org.fedoraproject.AnacondaInstaller.svg \
        /usr/share/icons/hicolor/scalable/apps/org.fedoraproject.AnacondaInstaller.svg; do
        cp "$_icon" "$f"
    done
    cp "$_icon_symbol" /usr/share/icons/hicolor/symbolic/apps/org.fedoraproject.AnacondaInstaller-symbolic.svg
fi
unset -v _icon
unset -v _icon_symbol

# Default Kickstart
cat <<EOF >>/usr/share/anaconda/interactive-defaults.ks

# Create log directory
%pre
mkdir -p /tmp/anacoda_custom_logs
%end

# Check if there is a bitlocker partition and ask the user to disable it
%pre --erroronfail --log=/tmp/anacoda_custom_logs/detect_bitlocker.log
DOCS_QR=/tmp/detect_bitlocker_qr.png
IS_BITLOCKER=\$(lsblk -o FSTYPE --json | jq '.blockdevices | map(select(.fstype == "BitLocker")) | . != []')
{ WARNING_MSG="\$(</dev/stdin)"; } << 'WARNINGEOF'
<span size="x-large">Windows Bitlocker partition detected</span>

It might interrupt the installation process.
In such case, please, do <b>one</b> of the following:
    a) Disconnect its storage drive.
    b) Disable Bitlocker in Windows.
    c) Delete it in GNOME Disks.

Do you wish to continue?
WARNINGEOF

if [[ \$IS_BITLOCKER =~ true ]]; then
    qrencode -o \$DOCS_QR "https://www.wikihow.com/Turn-Off-BitLocker"
    _EXITLOCK=1
    _RETCODE=0
    while [[ \$_EXITLOCK -ne 0 ]]; do
        run0 --user=liveuser yad \
            --on-top \
            --timeout=10 \
            --image=\$DOCS_QR \
            --text="\$WARNING_MSG" \
            --button="Yes, I'm aware, continue":0 --button="Cancel installation":10
        _RETCODE=\$?
        case \$_RETCODE in
            0) _EXITLOCK=0; ;;
            10) _EXITLOCK=0; pkill liveinst; pkill firefox; exit 0 ;;
        esac
    done
fi
%end

# Remove the efi dir, must match efi_dir from the profile config
%pre-install --erroronfail
rm -rf /mnt/sysroot/boot/efi/EFI/fedora
%end

# Relabel the boot partition for the
%pre-install --erroronfail --log=/tmp/anacoda_custom_logs/repartitioning.log
set -x
xboot_dev=\$(findmnt -o SOURCE --nofsroot --noheadings -f --target /mnt/sysroot/boot)
if [[ -z \$xboot_dev ]]; then
  echo "ERROR: xboot_dev not found"
  exit 1
fi
e2label "\$xboot_dev" "rakuos_xboot"
%end

# Open a dialog with the installation logs
%onerror
run0 --user=liveuser yad \
    --timeout=0 \
    --text-info \
    --no-buttons \
    --width=600 \
    --height=400 \
    --text="An error occurred during installation. Please report this issue to the developers." \
    < /tmp/anaconda.log
%end

$(
    if [[ $imageref == *-deck* ]]; then
        cat <<EOCAT
# Set default user
user --name=rakuos --password=rakuos --plaintext --groups=wheel
EOCAT
    fi
)

ostreecontainer --url=$imageref:$imagetag --transport=containers-storage --no-signature-verification
%include /usr/share/anaconda/post-scripts/install-configure-upgrade.ks
%include /usr/share/anaconda/post-scripts/disable-fedora-flatpak.ks
%include /usr/share/anaconda/post-scripts/install-flatpaks.ks
%include /usr/share/anaconda/post-scripts/flatpak-restore-selinux-labels.ks

EOF

# Signed Images
cat <<EOF >>/usr/share/anaconda/post-scripts/install-configure-upgrade.ks
%post --erroronfail --log=/tmp/anacoda_custom_logs/bootc-switch.log
bootc switch --mutate-in-place --enforce-container-sigpolicy --transport registry $imageref:$imagetag
%end
EOF

### Desktop-enviroment specific tweaks ###
# Setup script to show dialog popups at login

# Use GSK_RENDERER=gl for nvidia, workaround for GTK apps not opening.
if [[ $imageref == */nvidia* ]]; then
    mkdir -p /etc/environment.d /etc/skel/.config/environment.d
    echo "GSK_RENDERER=gl" >>/etc/environment.d/99-nvidia-fix.conf
    echo "GSK_RENDERER=gl" >>/etc/skel/.config/environment.d/99-nvidia-fix.conf
fi

# Reenable noveau.
if [[ $imageref == */nvidia* ]]; then
    for pkg in nvidia-gpu-firmware mesa-vulkan-drivers; do
        dnf -yq reinstall --allowerasing $pkg ||
            dnf -yq install --allowerasing $pkg
    done
    # Ensure noveau vulkan icds exist
    (
        shopt -u nullglob
        ls /usr/share/vulkan/icd.d/nouveau_icd.*.json >/dev/null
    ) || {
        echo >&2 "::error::No nouveau vulkan icds found at /usr/share/vulkan/icd.d/nouveau_icd.*.json"
        exit 1
    }
fi


# Don't check for verified image
rm -vf /etc/profile.d/verify_motd.sh

echo "Copying shared system files..."
cp -af /root/packages/installer/system_files/shared/. /

echo "Copying kde-specific system files..."
cp -a /root/packages/installer/system_files/kde/. /

# Change default pins for KDE
sed -i '/const allPanels/,$d' /usr/share/plasma/layout-templates/org.kde.plasma.desktop.defaultPanel/contents/layout.js
sed -i '$r /usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/rakuos-pins.js' /usr/share/plasma/layout-templates/org.kde.plasma.desktop.defaultPanel/contents/layout.js

###############################
#remove rakuos-welcome automatic launch for live environment
rm -f /etc/xdg/autostart/rakuos-welcome.desktop

rm -rf /root/packages
