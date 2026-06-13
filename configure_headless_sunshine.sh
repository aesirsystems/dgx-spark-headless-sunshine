#!/usr/bin/env bash
# Configure a DGX Spark system for headless Sunshine streaming.
# This script must be run as root (e.g. sudo ./configure_headless_sunshine.sh).

set -euo pipefail

# --- Configuration (override via environment) ---------------------------------
# Sunshine .deb asset to install (matches the DGX Spark: Ubuntu 24.04 / ARM64).
SUNSHINE_DEB_ASSET="${SUNSHINE_DEB_ASSET:-sunshine-ubuntu-24.04-arm64.deb}"
# Pin a specific Sunshine release tag (e.g. v2026.516.143833). Default: latest stable.
SUNSHINE_VERSION="${SUNSHINE_VERSION:-}"
# Expected SHA-256 of the .deb. Default: taken from the GitHub asset metadata.
SUNSHINE_SHA256="${SUNSHINE_SHA256:-}"
# Opt-in firewall: set CONFIGURE_FIREWALL=1 and FIREWALL_ALLOW_CIDRS to restrict
# Sunshine's ports to specific networks (LAN/Tailscale). Default: off.
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-0}"
FIREWALL_ALLOW_CIDRS="${FIREWALL_ALLOW_CIDRS:-}"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root (try: sudo $0)" >&2
    exit 1
  fi
}

determine_target_user() {
  local user
  user="${TARGET_USER:-${SUDO_USER:-}}"
  if [[ -z "${user}" ]]; then
    echo "Unable to determine the non-root user. Set TARGET_USER=username when invoking this script." >&2
    exit 1
  fi
  if ! id "${user}" >/dev/null 2>&1; then
    echo "User ${user} does not exist on this system." >&2
    exit 1
  fi
  TARGET_USER="${user}"
  TARGET_HOME="$(eval echo "~${TARGET_USER}")"
  TARGET_UID="$(id -u "${TARGET_USER}")"
}

install_sunshine() {
  local deb_file="/tmp/${SUNSHINE_DEB_ASSET}"

  # Check if Sunshine is already installed
  if command -v sunshine >/dev/null 2>&1; then
    echo "Sunshine is already installed ($(sunshine --version 2>/dev/null || echo 'version unknown'))."
    return 0
  fi

  echo "Installing Sunshine streaming software..."

  # Resolve the release tag, download URL, and expected SHA-256 from the GitHub
  # Releases API. Defaults to the latest *stable* release (not pre-releases); set
  # SUNSHINE_VERSION to pin a specific tag for reproducible installs. The expected
  # SHA-256 comes from the GitHub asset metadata and is verified before install;
  # override it with SUNSHINE_SHA256 (e.g. for an air-gapped mirror).
  local api_url release_json
  if [[ -n "${SUNSHINE_VERSION}" ]]; then
    api_url="https://api.github.com/repos/LizardByte/Sunshine/releases/tags/${SUNSHINE_VERSION}"
  else
    api_url="https://api.github.com/repos/LizardByte/Sunshine/releases/latest"
  fi

  echo "Resolving Sunshine release from ${api_url}..."
  release_json="$(mktemp /tmp/sunshine-release.XXXXXX.json)"
  curl -fsSL -H 'Accept: application/vnd.github+json' "${api_url}" -o "${release_json}" || {
    echo "Failed to fetch Sunshine release information from GitHub." >&2
    rm -f "${release_json}"
    exit 1
  }

  local resolved tag sunshine_url expected_sha
  resolved="$(SUNSHINE_DEB_ASSET="${SUNSHINE_DEB_ASSET}" python3 - "${release_json}" <<'PY'
import json, os, sys

with open(sys.argv[1]) as fh:
    data = json.load(fh)

asset_name = os.environ["SUNSHINE_DEB_ASSET"]
tag = data.get("tag_name", "")
for asset in data.get("assets", []):
    if asset.get("name") == asset_name:
        digest = (asset.get("digest") or "").replace("sha256:", "")
        print(f"{tag}\t{asset.get('browser_download_url', '')}\t{digest}")
        break
else:
    sys.exit(f"Asset '{asset_name}' not found in Sunshine release '{tag}'.")
PY
)" || { echo "Could not locate ${SUNSHINE_DEB_ASSET} in the Sunshine release." >&2; rm -f "${release_json}"; exit 1; }
  rm -f "${release_json}"

  IFS=$'\t' read -r tag sunshine_url expected_sha <<<"${resolved}"
  expected_sha="${SUNSHINE_SHA256:-${expected_sha}}"

  echo "Sunshine release: ${tag}"
  echo "Downloading ${SUNSHINE_DEB_ASSET} from ${sunshine_url}..."
  wget -q --show-progress -O "${deb_file}" "${sunshine_url}" || {
    echo "Failed to download Sunshine package." >&2
    exit 1
  }

  # Verify integrity before installing anything onto the system.
  if [[ -n "${expected_sha}" ]]; then
    local actual_sha
    actual_sha="$(sha256sum "${deb_file}" | cut -d' ' -f1)"
    if [[ "${actual_sha}" != "${expected_sha}" ]]; then
      echo "ERROR: SHA-256 mismatch for ${deb_file}" >&2
      echo "  expected: ${expected_sha}" >&2
      echo "  actual:   ${actual_sha}" >&2
      rm -f "${deb_file}"
      exit 1
    fi
    echo "Verified SHA-256: ${actual_sha}"
  else
    echo "WARNING: GitHub returned no SHA-256 for ${SUNSHINE_DEB_ASSET}; integrity check skipped." >&2
  fi

  # Install dependencies
  echo "Installing Sunshine dependencies..."
  apt update -qq
  apt install -y -qq \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswscale-dev \
    libevdev-dev \
    libpulse-dev \
    libopus-dev \
    libxtst-dev \
    libx11-dev \
    libxrandr-dev \
    libxfixes-dev \
    libxcb1-dev \
    libxcb-shm0-dev \
    libxcb-xfixes0-dev \
    libdrm-dev \
    libcap-dev \
    libudev-dev \
    libwayland-dev \
    libinput-dev \
    libcurl4-openssl-dev \
    libssl-dev 2>/dev/null || true

  # Install Sunshine
  echo "Installing Sunshine package..."
  dpkg -i "${deb_file}" 2>/dev/null || {
    echo "Fixing broken dependencies..."
    apt --fix-broken install -y -qq
  }

  # Clean up
  rm -f "${deb_file}"

  # Verify installation
  if command -v sunshine >/dev/null 2>&1; then
    echo "Sunshine installed successfully ($(sunshine --version 2>/dev/null || echo 'installed'))."
  else
    echo "Warning: Sunshine installation may have failed. Please check manually." >&2
  fi
}

update_grub_cmdline() {
  python3 - <<'PY'
import re, shlex
from pathlib import Path

grub_path = Path("/etc/default/grub")
text = grub_path.read_text()
match = re.search(r'^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"', text, re.MULTILINE)
if not match:
    raise SystemExit("Unable to find GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub")

existing = shlex.split(match.group(1))
desired = ["nvidia-drm.modeset=1", "nvidia.NVreg_UsePageAttributeTable=1"]
for flag in desired:
    if flag not in existing:
        existing.append(flag)

replacement = f'GRUB_CMDLINE_LINUX_DEFAULT="{" ".join(existing)}"'
start, end = match.span()
text = text[:start] + replacement + text[end:]
grub_path.write_text(text)
PY

  echo "Regenerated GRUB command line with NVIDIA DRM modeset flags."
  update-grub
}

write_xorg_config() {
  local xorg_path="/etc/X11/xorg.conf"
  if [[ -f "${xorg_path}" && ! -f "${xorg_path}.backup-before-sunshine" ]]; then
    cp "${xorg_path}" "${xorg_path}.backup-before-sunshine"
  fi

  cat <<'EOF' > "${xorg_path}"
# Headless Xorg configuration for NVIDIA GB10 on DGX Spark
Section "ServerLayout"
    Identifier     "Layout0"
    Screen      0  "Screen0" 0 0
    InputDevice    "Keyboard0" "CoreKeyboard"
    InputDevice    "Mouse0" "CorePointer"
EndSection

Section "Files"
EndSection

Section "InputDevice"
    Identifier     "Mouse0"
    Driver         "mouse"
    Option         "Protocol" "auto"
    Option         "Device" "/dev/psaux"
    Option         "Emulate3Buttons" "no"
    Option         "ZAxisMapping" "4 5"
EndSection

Section "InputDevice"
    Identifier     "Keyboard0"
    Driver         "kbd"
EndSection

Section "Monitor"
    Identifier     "Monitor0"
    VendorName     "Virtual"
    ModelName      "Headless"
    Option         "DPMS"
EndSection

Section "Device"
    Identifier     "Device0"
    Driver         "nvidia"
    VendorName     "NVIDIA Corporation"
    BoardName      "NVIDIA GB10"
    Option         "AllowEmptyInitialConfiguration" "True"
    Option         "VirtualHeads" "1"
    Option         "ConnectedMonitor" "DFP-0"
    Option         "Coolbits" "28"
EndSection

Section "Screen"
    Identifier     "Screen0"
    Device         "Device0"
    Monitor        "Monitor0"
    DefaultDepth    24
    Option         "MetaModes" "HDMI-0: 1600x900 +0+0"
    SubSection     "Display"
        Virtual     1920 1080
        Depth       24
    EndSubSection
EndSection
EOF

  echo "Wrote headless Xorg configuration to ${xorg_path}."
}

configure_gdm() {
  AUTLOGIN_USER="${TARGET_USER}" python3 - <<'PY'
from pathlib import Path
from configparser import ConfigParser
import os

path = Path("/etc/gdm3/custom.conf")
parser = ConfigParser(strict=False, allow_no_value=True)
parser.optionxform = str  # Preserve option casing expected by GDM
parser.read(path)

if "daemon" not in parser:
    parser["daemon"] = {}

daemon = parser["daemon"]
for key in list(daemon.keys()):
    if key.lower() in {
        "waylandenable",
        "defaultsession",
        "automaticloginenable",
        "automaticlogin",
    }:
        daemon.pop(key)
daemon["WaylandEnable"] = "false"
daemon["DefaultSession"] = "gnome-xorg.desktop"
daemon["AutomaticLoginEnable"] = "true"
daemon["AutomaticLogin"] = os.environ["AUTLOGIN_USER"]

with path.open("w") as fh:
    parser.write(fh, space_around_delimiters=False)
PY

  echo "Configured GDM for Xorg and autologin (user ${TARGET_USER})."
}

install_autostart() {
  local autostart_dir="${TARGET_HOME}/.config/autostart"
  local desktop_file="${autostart_dir}/headless-xrandr.desktop"
  local xauth="/run/user/${TARGET_UID}/gdm/Xauthority"
  local runtime_dir="/run/user/${TARGET_UID}"

  install -d -m 755 -o "${TARGET_USER}" -g "${TARGET_USER}" "${autostart_dir}"

  cat <<EOF > "${desktop_file}"
[Desktop Entry]
Type=Application
Exec=/bin/sh -c '/usr/bin/xrandr --output HDMI-0 --mode 1600x900; sleep 5; if ! pgrep -x sunshine >/dev/null 2>&1; then DISPLAY=:0 XAUTHORITY=${xauth} XDG_RUNTIME_DIR=${runtime_dir} /usr/bin/sunshine & fi'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Headless Display Mode
EOF

  chown "${TARGET_USER}:${TARGET_USER}" "${desktop_file}"
  chmod 644 "${desktop_file}"

  echo "Installed GNOME autostart entry to set the dummy display and launch Sunshine."
}

configure_firewall() {
  if [[ "${CONFIGURE_FIREWALL}" != "1" ]]; then
    return 0
  fi

  if ! command -v ufw >/dev/null 2>&1; then
    echo "CONFIGURE_FIREWALL=1 but ufw is not installed; skipping firewall setup." >&2
    return 0
  fi

  if [[ -z "${FIREWALL_ALLOW_CIDRS}" ]]; then
    echo "CONFIGURE_FIREWALL=1 requires FIREWALL_ALLOW_CIDRS (comma-separated)." >&2
    echo "Example: FIREWALL_ALLOW_CIDRS=\"172.20.100.0/24,100.64.0.0/10\" (LAN, Tailscale)." >&2
    echo "Refusing to expose Sunshine to all networks; skipping firewall setup." >&2
    return 1
  fi

  # Sunshine default ports (base port 47989). Restricted to the given networks.
  # See https://docs.lizardbyte.dev/projects/sunshine/latest/ for the port model.
  local tcp_ports="47984,47989,47990,48010"
  local udp_ports="47998,47999,48000,48002"

  # Never lock ourselves out of SSH when enabling the firewall.
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true

  local cidr
  local IFS=','
  for cidr in ${FIREWALL_ALLOW_CIDRS}; do
    cidr="${cidr// /}"
    [[ -z "${cidr}" ]] && continue
    ufw allow from "${cidr}" to any port "${tcp_ports}" proto tcp comment "Sunshine TCP"
    ufw allow from "${cidr}" to any port "${udp_ports}" proto udp comment "Sunshine UDP"
    echo "Allowed Sunshine ports from ${cidr}."
  done

  ufw --force enable
  echo "Firewall configured (ufw); Sunshine reachable only from: ${FIREWALL_ALLOW_CIDRS}"
}

main() {
  require_root
  determine_target_user
  install_sunshine
  update_grub_cmdline
  write_xorg_config
  configure_gdm
  install_autostart
  configure_firewall

  cat <<EOM

Configuration complete. Next steps:
  1. Reboot the system so the new GRUB command line and Xorg configuration take effect.
  2. Allow the autologin session to initialize; the GNOME autostart entry will set the 1600x900 mode and launch Sunshine.
  3. Access Sunshine Web UI at: https://$(hostname):47990/ or https://$(hostname -I | awk '{print $1}'):47990/
     IMPORTANT: Use HTTPS (not HTTP) - you will need to accept the self-signed certificate warning.
  4. SET YOUR SUNSHINE USERNAME AND PASSWORD IMMEDIATELY on first access. Until you do, the
     web UI is unauthenticated and the first client to reach it can claim the admin account.
  5. Pair Moonlight with this host using the PIN from https://$(hostname):47990/pin

Security notes:
  - Automatic login is enabled for user "${TARGET_USER}". Disable via /etc/gdm3/custom.conf
    (AutomaticLoginEnable=false) if console access to this machine is a concern.
  - Sunshine listens on all interfaces. To restrict it to specific networks, re-run with:
    sudo CONFIGURE_FIREWALL=1 FIREWALL_ALLOW_CIDRS="<LAN/Tailscale CIDRs>" ./configure_headless_sunshine.sh
EOM
}

main "$@"

