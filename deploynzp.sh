#!/bin/bash
set -euxo pipefail # Exit on failure, log all commands

# --- Sanity Check ---
# Ensure the required environment variable is set
if [ -z "${NZP_RCON_PASSWORD}" ]; then
  echo "Error: NZP_RCON_PASSWORD environment variable is not set." >&2
  exit 1
fi
# --- End Sanity Check ---

# Set Timezone
timedatectl set-timezone America/Detroit

# Create Swap File
if ! swapon --show | grep -q /swapfile; then # Check if swap already exists/enabled
    fallocate -l 3G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
    echo "Swap file /swapfile already configured."
fi

# Download and Extract NZP Server
# Only download/extract if the executable doesn't exist
if [ ! -f /root/nzportable64-sdl ]; then
    cd /root
    # Ensure wget and unzip are installed (cloud-init should handle this, but belt-and-suspenders)
    apt-get update && apt-get install -y wget unzip || true # Allow failure if already installed/updated
    wget https://github.com/nzp-team/nzportable/releases/download/nightly/nzportable-linux64.zip
    unzip nzportable-linux64.zip
    rm nzportable-linux64.zip
    chmod +x /root/nzportable64-sdl
else
    echo "NZP executable /root/nzportable64-sdl already exists. Skipping download/extract."
    # Ensure executable permission is set regardless
    chmod +x /root/nzportable64-sdl
fi


# Create Systemd Service using a placeholder for the password
# Using a unique placeholder avoids accidental replacement if the password contains __RCON__ etc.
RCON_PLACEHOLDER="__NZP_RCON_PASSWORD_REPLACE_ME__"
cat > /etc/systemd/system/nzp.service <<'EOF'
[Unit]
Description=NZP Dedicated Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/root
# Use a placeholder for the password here
ExecStart=/root/nzportable64-sdl -dedicated +map weapon_test +set sv_port_tcp 400 +set com_protocolname NZP-REBOOT +sv_public 0 +set rcon_password "__NZP_RCON_PASSWORD_REPLACE_ME__"
Restart=on-failure
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

# Replace the placeholder with the actual password from the environment variable
# Using sed with a different delimiter (|) avoids issues if the password contains slashes (/)
sed -i "s|${RCON_PLACEHOLDER}|${NZP_RCON_PASSWORD}|g" /etc/systemd/system/nzp.service

# Enable Service
systemctl daemon-reload
systemctl enable --now nzp.service

# Configure Unattended-Upgrades (only if files don't exist or differ significantly)
# This prevents unnecessary rewrites on subsequent runs if using a tool that re-runs cloud-init
mkdir -p /etc/apt/apt.conf.d/

cat > /etc/apt/apt.conf.d/10periodic <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7"; # Clean more reasonably, daily is excessive
APT::Periodic::Unattended-Upgrade "1";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
// Automatically upgrade packages from these (origin:archive) pairs
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}";
        "${distro_id}:${distro_codename}-security";
        // Ubuntu Pro / ESM settings commented out unless specifically needed/enabled
        // "${distro_id}ESMApps:${distro_codename}-apps-security";
        // "${distro_id}ESM:${distro_codename}-infra-security";
        "${distro_id}:${distro_codename}-updates";
//      "${distro_id}:${distro_codename}-proposed"; // Proposed is usually not recommended for production
        "${distro_id}:${distro_codename}-backports";
};

// List packages to prevent upgrading (e.g., kernel, specific drivers)
Unattended-Upgrade::Package-Blacklist {
//      "linux-generic";
//      "linux-image-generic";
//      "linux-headers-generic";
};

Unattended-Upgrade::DevRelease "auto"; // Keep "auto" unless you specifically want testing releases
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true"; // This one is default true usually
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true"; // Reboot even if users are logged in
Unattended-Upgrade::Automatic-Reboot-Time "03:00"; // Specify timezone via system time (set above)
// Unattended-Upgrade::Allow-APT-Mark-Fallback "true"; // Usually not needed unless dealing with complex pinning
EOF

reboot
