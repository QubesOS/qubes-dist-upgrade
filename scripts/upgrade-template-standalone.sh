#!/usr/bin/bash

# Frédéric Pierret (fepitre) frederic.pierret@qubes-os.org

# Exit codes:
# 0: OK
# 1: General errors
# 2: Unsupported distribution
# 3: Upgrade failed

set -ex

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run with root permissions" 
   exit 1
fi

if [ -e /etc/fedora-release ]; then
    releasever="$(awk '{print $3}' /etc/fedora-release)"
    # Check Fedora supported release
    if [ "$releasever" -lt 32 ]; then
        exit 2
    fi
    # Backup R4.0 repository file
    cp /etc/yum.repos.d/qubes-r4.repo /etc/yum.repos.d/qubes-r4.repo.bak
    # We don't have $releasever into so manually replace it
    sed -i 's/r4.0/r4.1/g' /etc/yum.repos.d/qubes-r4.repo
    # Ensure DNF cache is cleaned
    dnf clean all
    # Run upgrade
    if ! dnf distro-sync -y --best --allowerasing; then
        exit 3
    fi
    # Removing xen-qubes-vm pkg disables this service, even though it's still
    # present in the system (via xen-runtime package now).
    systemctl preset xendriverdomain
elif [ -e /etc/debian_version ]; then
    releasever="$(awk -F'.' '{print $1}' /etc/debian_version)"
    # Check Debian supported release
    if [ "$releasever" -lt 10 ]; then
        exit 2
    fi
    # Backup R4.0 repository file
    cp /etc/apt/sources.list.d/qubes-r4.list /etc/apt/sources.list.d/qubes-r4.list.bak
    # We don't have $releasever into so manually replace it
    sed -i 's/r4.0/r4.1/g' /etc/apt/sources.list.d/qubes-r4.list
    # Ensure APT cache is cleaned
    apt-get clean
    apt-get update
    # "downgrade" to package without epoch
    if ! apt-get install --allow-downgrades -y \
            'xen-utils-common=4.14*' \
            'libxenstore3.0=4.14*' \
            'xenstore-utils=4.14*'; then
        exit 3
    fi
    # restaring qrexec-agent would interrupt the update
    cat > /usr/sbin/policy-rc.d <<EOF
#!/bin/sh
[ "\$1" = "--quiet" ] && shift
case "\$1" in
qubes-qrexec-agent.service) exit 101;; # Action forbidden by policy
*) exit 104;; # Action allowed
esac
EOF
    chmod 755 /usr/sbin/policy-rc.d
    trap "rm -f /usr/sbin/policy-rc.d" EXIT
    # Run upgrade, without installing "recommended" packages - that would
    # un-minimal an minimal template
    if ! apt dist-upgrade -y --no-install-recommends; then
        exit 3
    fi
fi
