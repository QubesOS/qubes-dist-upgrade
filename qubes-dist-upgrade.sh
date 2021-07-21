#!/bin/bash

# Frédéric Pierret (fepitre) frederic.pierret@qubes-os.org

set -e
if [ "${VERBOSE:-0}" -ge 2 ] || [ "${DEBUG:-0}" -eq 1 ]; then
    set -x
fi

scriptsdir=/usr/lib/qubes

#-----------------------------------------------------------------------------#

usage() {
echo "Usage: $0 [OPTIONS]...

This script is used for updating current QubesOS R4.0 to R4.1.

Options:
    --double-metadata-size, -d         (STAGE 0) Double current LVM thin pool metadata size.
    --update, -t                       (STAGE 1) Update of dom0, TemplatesVM and StandaloneVM.
    --template-standalone-upgrade, -l  (STAGE 2) Upgrade templates and standalone VMs to R4.1 repository.
    --release-upgrade, -r              (STAGE 3) Update 'qubes-release' for Qubes R4.1.
    --dist-upgrade, -s                 (STAGE 4) Upgrade to Qubes R4.1 and Fedora 32 repositories.
    --setup-efi-grub, -g               (STAGE 5) Setup EFI Grub.
    --all, -a                          Execute all the above stages in one call.

    --assumeyes, -y                    Automatically answer yes for all questions.
    --usbvm, -u                        Current UsbVM defined (default 'sys-usb').
    --netvm, -n                        Current NetVM defined (default 'sys-net').
    --updatevm, -f                     Current UpdateVM defined (default 'sys-firewall').
    --skip-template-upgrade, -j        Don't upgrade TemplateVM to R4.1 repositories.
    --skip-standalone-upgrade, -k      Don't upgrade StandaloneVM to R4.1 repositories.
    --only-update                      Apply STAGE 0, 2 and resync appmenus only to
                                       selected qubes (coma separated list).
    --max-concurrency                  How many TemplateVM/StandaloneVM to update in parallel in STAGE 1
                                       (default 4).

    --resync-appmenus-features         Resync applications and features. To be ran individually
                                       after reboot.
"
    exit 1
}

exit_migration() {
    local exit_code=$?
    if [ $exit_code -gt 0 ]; then
        echo "-> Launch restoration..."
        if ! is_qubes_uefi && [ -e /backup/default_grub ]; then
            # In case of any manual modifications
            echo "---> Restoring legacy Grub..."
            mkdir -p /etc/default/
            cp /backup/default_grub /etc/default/grub
            grub2-mkconfig -o /boot/grub2/grub.cfg
        fi
        if is_qubes_uefi && [ -e /backup/efi_disk ]; then
            if [ -e /backup/boot.img ] && [ -e /backup/partitions_table.txt ] && [ -e /backup/fstab ] && [ -e /backup/efi_part ]; then
                echo "---> Restoring EFI boot partition..."
                umount /boot/efi || true
                umount /boot || true
                # Restore partition table
                sfdisk --no-reread -f "$(cat /backup/efi_disk)" < /backup/partitions_table.txt
                # Resync partition
                partprobe
                # Restore boot partition
                dd if=/backup/boot.img of="$(cat /backup/efi_part)"
                # Remount previous EFI part
                cp /backup/fstab /etc/fstab
                mkdir -p /boot/efi
                mount /boot/efi
            fi
            echo "---> Restoring EFI boot manager..."
            # Restore EFI boot manager entry
            efibootmgr_entry="$(efibootmgr -v | grep "Qubes" | awk '{print $1}')"
            efibootmgr_entry="${efibootmgr_entry//Boot/}"
            efibootmgr_entry="${efibootmgr_entry//\*/}"
            if [ -n "$efibootmgr_entry" ]; then
                efibootmgr -b "$efibootmgr_entry" -B
            fi
            efibootmgr -c -d "$(cat /backup/efi_disk)" -L Qubes -l '\EFI\qubes\xen.efi'
            # Remove previous default grub conf created
            rm -rf /etc/default/grub
        fi
    fi
    exit "$exit_code"
}

confirm() {
    read -r -p "${1} [y/N] " response
    case "$response" in
        [yY]) 
            true
            ;;
        *)
            false
            ;;
    esac
}

get_reference_from_fstab() {
    local mountpoint="$1"
    if [ -n "$mountpoint" ]; then
        sed '/^[[:blank:]]*#/d' /etc/fstab | grep -Po "^[^ \t]+[ \t]+${mountpoint}[ \t]+" | awk '{print $1}'
    fi
}

is_boot_partition_exists() {
    boot="$(get_reference_from_fstab /boot)"
    test -n "$boot"
}

is_qubes_uefi() {
    boot_efi="$(get_reference_from_fstab /boot/efi)"
    test -n "$boot_efi"
}

get_uuid_from_mountpoint() {
    reference="$(get_reference_from_fstab "$1")"
    if [ "${reference/UUID=}" != "$reference" ]; then
        echo "${reference/UUID=}"
    else
        get_uuid_from_block "$reference"
    fi
}

get_uuid_from_block() {
    local blockpoint="$1"
    if [ -n "$blockpoint" ]; then
        lsblk -no uuid "$blockpoint"
    fi
}

get_disk_from_uuid() {
    local uuid="$1"
    if [ -n "$uuid" ]; then
        lsblk -no pkname "/dev/disk/by-uuid/$uuid"
    fi
}

get_partnumber_from_uuid() {
    local uuid="$1"
    if [ -n "$uuid" ]; then
        disk="$(get_disk_from_uuid "$uuid")"
        partnumber="$(lsblk -no name "/dev/disk/by-uuid/$uuid")"
        partnumber="${partnumber//$disk/}"
        # possibly with prefix 'p'
        echo "$partnumber"
    fi
}

get_available_partnumber() {
    local disk="$1"
    if [ -b "$disk" ]; then
        partitions_list="$(fdisk -l "$disk" | grep "^$disk" | awk -v disk="$disk" '{ gsub(disk,"",$1); print $1 }')"
        last_partnumber="$(echo "$partitions_list" | tail -1)"
        last_partnumber="${last_partnumber//p/}"
        if [ -n "$last_partnumber" ]; then
            echo "$((last_partnumber + 1))"
        fi
    fi
}

get_boot_efi_size(){
    local uuid
    efi_uuid="$(get_uuid_from_mountpoint /boot/efi)"
    if [ -n "$efi_uuid" ]; then
        lsblk -b -no size "/dev/disk/by-uuid/$efi_uuid"
    fi
}

update_prechecks() {
    if ! is_boot_partition_exists; then
        if is_qubes_uefi; then
            efi_uuid="$(get_uuid_from_mountpoint /boot/efi)"
            if [ -n "$efi_uuid" ]; then
                # Minimum size for boot partition: 500Mo
                min_efi_size=524288000
                efi_boot_size="$(get_boot_efi_size)"
                if [ "${efi_boot_size:-0}" -lt "$min_efi_size" ]; then
                    echo "WARNING: EFI boot partitition size is less than 500Mo."
                fi
            else
                echo "ERROR: Cannot find EFI boot partitition UUID."
                exit 1
            fi
        fi
    fi
    # updatevm_template="$(qvm-prefs "$updatevm" template)"
    # if [ "$updatevm_template" != "fedora-30" ] && [ "$updatevm_template" != "debian-10" ]; then
    #    echo "ERROR: UpdateVM should be a Fedora 30+ or Debian 10+ template based VM."
    #    exit 1
    # fi
}

default_grub_config() {
cat > /etc/default/grub << EOF
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="\$(sed 's, release .*$,,g' /etc/system-release)"
GRUB_DEFAULT=saved
GRUB_TERMINAL_OUTPUT="gfxterm"
GRUB_CMDLINE_LINUX="@GRUB_CMDLINE_LINUX@"
GRUB_CMDLINE_XEN_DEFAULT="@GRUB_CMDLINE_XEN_DEFAULT@"
GRUB_DISABLE_RECOVERY="true"
GRUB_THEME="/boot/grub2/themes/qubes/theme.txt"
GRUB_DISABLE_OS_PROBER="true"
EOF
}

update_default_grub_config() {
    # Use current default options
    sed -i "s|@GRUB_CMDLINE_LINUX@|$(cat /tmp/kernel_cmdline)|g" /etc/default/grub
    sed -i "s|@GRUB_CMDLINE_XEN_DEFAULT@|$(cat /tmp/xen_cmdline)|g" /etc/default/grub
    sed -i '/^GRUB_DISABLE_SUBMENU=.*/d' /etc/default/grub
    sed -i 's|^GRUB_THEME=.*|GRUB_THEME="/boot/grub2/themes/qubes/theme.txt"|g' /etc/default/grub
}

update_legacy_grub() {
    if ! is_qubes_uefi; then
        if [ -e /etc/default/grub ]; then
            echo "---> Updating Grub..."
            mkdir -p /backup
            if [ -e /backup/default_grub ]; then
                mv /backup/default_grub "/backup/default_grub-$(date +%s)"
            fi
            cp /etc/default/grub /backup/default_grub
            update_default_grub_config
            grub2-mkconfig -o /boot/grub2/grub.cfg
        fi

        # Set default plymouth theme
        plymouth-set-default-theme qubes-dark

        # Regenerate initrd
        # We need to pick latest version before reboot
        # shellcheck disable=SC2012
        dracut -f --kver "$(ls -1 /lib/modules/ | sort -V | tail -1)"
    fi
}

setup_efi_grub() {
    # backup current /boot including efi
    if [ ! -d /backup/boot ]; then
        mkdir -p /backup/
        cp -ar /boot /backup/
        if [ -d /backup/boot/efi ]; then
            mv /backup/boot/efi /backup/
        fi
    else
        echo "INFO: Boot backup folder already exists at /backup. Skipping."
    fi

    # backup current fstab
    if [ ! -e /backup/fstab ]; then
        cp /etc/fstab /backup/fstab
    else
        echo "INFO: fstab backup already exists at /backup. Skipping."
    fi

    if is_qubes_uefi; then
        umount /boot/efi || true
        efi_uuid="$(get_uuid_from_mountpoint /boot/efi)"
        efi_part_number="$(get_partnumber_from_uuid "$efi_uuid")"
        efi_disk="$(get_disk_from_uuid "$efi_uuid")"
        if [ -z "${efi_part_number}" ] || [ ! -b "/dev/${efi_disk}" ]; then
            echo "ERROR: Cannot find EFI part number and disk."
            exit 1
        fi
        echo "/dev/${efi_disk}" > /backup/efi_disk
        if ! is_boot_partition_exists; then
            available_partnumber="$(get_available_partnumber "/dev/${efi_disk}")"
            if [ -z "${available_partnumber}" ]; then
                echo "ERROR: Cannot find available partition number."
                exit 1
            fi
            if [ "${efi_part_number:0:1}" == "p" ]; then
                part_path="/dev/${efi_disk}p"
            else
                part_path="/dev/${efi_disk}"
            fi
            # We extracted disk path of partition. Keep only number
            efi_part_number="${efi_part_number//p/}"
            # Backup
            if [ ! -e /backup/boot.img ] && [ ! -e /boot/partitions_table.txt ]; then
                dd if="${part_path}${efi_part_number}" of="/backup/boot.img"
                sfdisk -d "/dev/${efi_disk}" > "/backup/partitions_table.txt"
                echo "${part_path}${efi_part_number}" > /backup/efi_part
            else
                echo "INFO: Boot and partitions table backup already exists at /backup. Skipping."
            fi

            # Get EFI FS partition type for distinguishing Apple case
            efi_part_fstype="$(lsblk -no fstype "${part_path}${efi_part_number}")"

            # Recreate EFI partition at the same position
            # Create Boot partition at third position
            printf "d\n%s\nn\n%s\n\n+25M\nn\n%s\n\n\nt\n%s\n1\nw\n" "${efi_part_number}" "${efi_part_number}" "${available_partnumber}" "${efi_part_number}" | fdisk --wipe-partition always "/dev/$efi_disk"

            # Check new boot partition has been created
            newavailable_partnumber="$(get_available_partnumber "/dev/${efi_disk}")"
            if [ "$newavailable_partnumber" == "$available_partnumber" ] || [ ! -b "${part_path}${available_partnumber}" ]; then
                echo "ERROR: An error occured while creating boot partition"
                exit 1
            fi

            # Set new partition EFI boot with the same UUID as previous
            if [ "${efi_part_fstype}" == "hfsplus" ]; then
                mkfs.hfsplus -U "$efi_uuid" "${part_path}${efi_part_number}"
            else
                volid=${efi_uuid/-/}
                mkfs.vfat -i "$volid" "${part_path}${efi_part_number}"
            fi
            # Boot partition
            mkfs.ext4 "${part_path}${available_partnumber}"

            # shellcheck disable=SC2115
            rm -rf /boot/*
            mount "${part_path}${available_partnumber}" /boot
            
            mkdir -p /boot/efi
            mount "${part_path}${efi_part_number}" /boot/efi

            # Copy current /boot into new partition /boot
            # including EFI boot partition content
            cp -r /backup/boot/* /boot/
            mkdir -p /boot/efi/EFI/qubes/fonts /boot/efi/EFI/qubes/entries
            cp -ar /backup/efi/EFI/qubes/fonts /boot/efi/EFI/qubes/
            cp -a /backup/efi/EFI/qubes/grubx64.efi /boot/efi/EFI/qubes/

            # Replace block reference in fstab by UUID
            # for /boot/efi it needed
            if ! grep -q "UUID=$efi_uuid" /etc/fstab; then
                boot_efi_ref="$(get_reference_from_fstab /boot/efi)"
                sed -i "s|$boot_efi_ref|UUID=$efi_uuid|g" /etc/fstab
            fi

            # Add entry for /boot partition
            boot_uuid="$(get_uuid_from_block "${part_path}${available_partnumber}")"
            # There is no reason for boot_uuid being empty
            # but in case we fallback to known entry point
            if [ -n "$boot_uuid" ]; then
                echo "UUID=$boot_uuid    /boot    ext4    defaults    1 2" >> /etc/fstab
            else
                echo "${part_path}${available_partnumber}    /boot    ext4    defaults    1 2" >> /etc/fstab
            fi    
        fi
        # Modifiy EFI boot manager
        efibootmgr_entry="$(efibootmgr -v | grep "Qubes" | awk '{print $1}')"
        efibootmgr_entry="${efibootmgr_entry//Boot/}"
        efibootmgr_entry="${efibootmgr_entry//\*/}"
        if [ -n "$efibootmgr_entry" ]; then
            efibootmgr -b "$efibootmgr_entry" -B
        fi
        efibootmgr -c -d "/dev/${efi_disk}" -L Qubes -l '\EFI\qubes\grubx64.efi'

        # Create default Grub config
        default_grub_config
        update_default_grub_config

        # Create Grub config
        mount /boot/efi || true
        grub2-editenv /boot/efi/EFI/qubes/grubenv create
        pushd /boot/grub2/
        ln -sf ../efi/EFI/qubes/grubenv .
        popd
        grub2-mkconfig -o /boot/efi/EFI/qubes/grub.cfg

        # Copy font
        mkdir -p /boot/efi/EFI/qubes/fonts/
        cp /usr/share/grub/unicode.pf2 /boot/efi/EFI/qubes/fonts/

        # Set default plymouth theme
        plymouth-set-default-theme qubes-dark

        # Regenerate initrd
        # shellcheck disable=SC2012
        dracut -f --kver "$(ls -1 /lib/modules/ | sort -V | tail -1)"
    fi
}

get_thin_pool_name() {
    local root_dev root_pool
    root_dev=$(df --output=source / | tail -1)
    case "$root_dev" in (/dev/mapper/*) ;; (*) return;; esac
    root_pool=$(lvs --no-headings --separator=/ -o vg_name,pool_lv "$root_dev" | tr -d ' ')
    echo "$root_pool"
}

get_pool_size() {
    # we remove leading space
    lvs --no-headings -o size "$1" --nosuffix --units b | tr -d ' '
}

get_tmeta_size() {
    # we remove leading space
    lvs --no-headings -o size "${1}_tmeta" --nosuffix --units b | tr -d ' '
}

recommended_size() {
    local pool_size
    local block_size="64k"
    local max_thins="1000"
    pool_size="$(get_pool_size "$1")"
    if [ "$pool_size" -ge 1 ]; then
        reco_tmeta_size="$(thin_metadata_size -n -u b --block-size="$block_size" --pool-size="$pool_size"b --max-thins="$max_thins")"
    fi
    # returned size unit is bytes
    echo "$((2*reco_tmeta_size))"
}

set_tmeta_size() {
    local metadata_size
    metadata_size="$(recommended_size "$1")"
    if [ -n "$metadata_size" ]; then
        lvextend -L "$metadata_size"b "${1}_tmeta"
    fi
}

shutdown_nonessential_vms() {
    mapfile -t running_vms < <(qvm-ls --running --raw-list --fields name 2>/dev/null)
    keep_running=( dom0 "$usbvm" "$netvm" "$updatevm")

    for vm in "${keep_running[@]}"
    do
        for i in "${!running_vms[@]}"
        do
            if [ "${running_vms[i]}" == "$vm" ]; then
                unset "running_vms[i]"
            fi
        done
    done

    # Ask before shutdown
    if [ ${#running_vms[@]} -gt 0 ]; then
        if [ "$assumeyes" == "1" ] || confirm "---> Allow shutdown of unnecessary VM: ${running_vms[*]}?"; then
            qvm-shutdown --wait "${running_vms[@]}"
        else
            exit 0
        fi
    fi
}

#-----------------------------------------------------------------------------#

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run with root permissions" 
   exit 1
fi

if ! OPTS=$(getopt -o htrlsgydu:n:f:jkp --long help,all,update,template-standalone-upgrade,release-upgrade,dist-upgrade,setup-efi-grub,assumeyes,double-metadata-size,usbvm:,netvm:,updatevm:,skip-template-upgrade,skip-standalone-upgrade,resync-appmenus-features,only-update:,max-concurrency: -n "$0" -- "$@"); then
    echo "ERROR: Failed while parsing options."
    exit 1
fi

eval set -- "$OPTS"

# Common DNF options
dnf_opts_noclean='--best --allowerasing --enablerepo=*testing*'

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help) usage ;;
        -a | --all)
            update=1
            template_standalone_upgrade=1
            release_upgrade=1
            dist_upgrade=1
            update_grub=1
            double_metadata_size=1
            ;;
        -t | --update ) update=1;;
        -r | --release-upgrade) release_upgrade=1;;
        -l | --template-standalone-upgrade) template_standalone_upgrade=1;;
        -s | --dist-upgrade ) dist_upgrade=1;;
        -g | --setup-efi-grub ) update_grub=1;;
        -y | --assumeyes ) assumeyes=1;;
        -d | --double-metadata-size ) double_metadata_size=1;;
        -u | --usbvm ) usbvm="$2"; shift ;;
        -n | --netvm ) netvm="$2"; shift ;;
        -f | --updatevm ) updatevm="$2"; shift ;;
        --only-update) only_update="$2"; shift ;;
        --max-concurrency) max_concurrency="$2"; shift ;;
        -j | --skip-template-upgrade ) skip_template_upgrade=1;;
        -k | --skip-standalone-upgrade ) skip_standalone_upgrade=1;;
        -p | --resync-appmenus-features ) resync_appmenus_features=1;;
    esac
    shift
done

if [ "$assumeyes" == "1" ];  then
    dnf_opts_noclean="${dnf_opts_noclean} -y"
fi

dnf_opts="--clean ${dnf_opts_noclean}"

# Default values
usbvm="${usbvm:-sys-usb}"
netvm="${netvm:-sys-net}"
updatevm="${updatevm:-sys-firewall}"
max_concurrency="${max_concurrency:-4}"

# Run prechecks first
update_prechecks

# Executing qubes.PostInstall and that's all
if [ "$resync_appmenus_features" == 1 ]; then
    if [ "$skip_template_upgrade" != 1 ]; then
        mapfile -t template_vms < <(for vm in $(qvm-ls --raw-list --fields name); do if qvm-check -q --template "$vm"; then echo "$vm"; fi; done 2>/dev/null)
    fi
    if [ "$skip_template_upgrade" != 1 ]; then
        mapfile -t standalone_vms < <(for vm in $(qvm-ls --raw-list --fields name); do if qvm-check -q --standalone "$vm"; then echo "$vm"; fi; done 2>/dev/null)
    fi
    if [ "$skip_template_upgrade" != 1 ] || [ "$skip_standalone_upgrade" != 1 ]; then
        mapfile -t all_vms < <(echo "${template_vms[@]}" "${standalone_vms[@]}")
    fi
    if [ -n "$only_update" ]; then
        IFS=, read -ra all_vms <<<"${only_update}"
    fi
    if [ "${#all_vms[*]}" -gt 0 ]; then
        for vm in ${all_vms[*]};
        do
            if ! qvm-run --service "$vm" qubes.PostInstall; then
                echo "WARNING: Failed to execute qubes.PostInstall in $vm."
            fi
            qvm-shutdown "$vm"
        done
    fi
    exit 0
fi

trap 'exit_migration' 0 1 2 3 6 15
# shellcheck disable=SC1003
echo 'WARNING: /!\ ENSURE TO HAVE MADE A BACKUP OF ALL YOUR VMs AND dom0 DATA /!\'
if [ "$assumeyes" == "1" ] || confirm "-> Launch upgrade process?"; then
    # Backup xen and kernel cmdline
    cat /proc/cmdline > /tmp/kernel_cmdline
    xl info xen_commandline > /tmp/xen_cmdline || {
        echo "ERROR: Failed to get Xen cmdline, have you restarted the system after previous upgrade stage?"
        exit 1
    }

    # Shutdown nonessential VMs
    shutdown_nonessential_vms

    pool_name=$(get_thin_pool_name)
    if [ "$double_metadata_size" == 1 ]; then
        if [ -z "$pool_name" ]; then
            echo "---> (STAGE 0) Skipping - no LVM thin pool found"
        elif [ "$(get_tmeta_size "$pool_name")" -ge "$(recommended_size "$pool_name")" ]; then
            echo "---> (STAGE 0) Skipping - already right size"
        else
            echo "---> (STAGE 0) Adjusting LVM thin pool metadata size..."
            set_tmeta_size "$pool_name"
        fi
    fi

    if [ "$update" == "1" ]; then
        # Ensure 'gui' and 'qrexec' in default template used
        # for management else 'qubesctl' will failed
        management_template="$(qvm-prefs "$(qubes-prefs management_dispvm)" template)"
        if [ -n "$management_template" ]; then
            qvm-features "$management_template" gui 1
            qvm-features "$management_template" qrexec 1
        else
            echo "ERROR: Cannot find default management template."
            exit 1
        fi

        echo "---> (STAGE 1) Updating dom0..."
        # we need qubes-mgmt-salt-dom0-update >= 4.0.5
        # shellcheck disable=SC2086
        qubes-dom0-update $dnf_opts
        echo "---> (STAGE 1) Updating Templates VMs and StandaloneVMs..."
        if [ -n "$only_update" ]; then
            qubesctl --skip-dom0 --max-concurrency="$max_concurrency" \
                --targets="${only_update}" state.sls update.qubes-vm
        else
            qubesctl --skip-dom0 --max-concurrency="$max_concurrency" \
                --templates state.sls update.qubes-vm
            qubesctl --skip-dom0 --max-concurrency="$max_concurrency" \
                --standalones state.sls update.qubes-vm
        fi

        # Shutdown nonessential VMs again if some would have other NetVM than UpdateVM (e.g. sys-whonix)
        shutdown_nonessential_vms

        # Restart UpdateVM with updated templates (several fixes)
        qvm-shutdown --wait "$updatevm"
    fi

    if [ "$template_standalone_upgrade" == 1 ]; then
        echo "---> (STAGE 2) Upgrade templates and standalone VMs to R4.1 repository..."
        if [ "$skip_template_upgrade" != 1 ]; then
            mapfile -t template_vms < <(for vm in $(qvm-ls --raw-list --fields name); do if qvm-check -q --template "$vm"; then echo "$vm"; fi; done 2>/dev/null)
        fi
        if [ "$skip_template_upgrade" != 1 ]; then
            mapfile -t standalone_vms < <(for vm in $(qvm-ls --raw-list --fields name); do if qvm-check -q --standalone "$vm"; then echo "$vm"; fi; done 2>/dev/null)
        fi
        if [ "$skip_template_upgrade" != 1 ] || [ "$skip_standalone_upgrade" != 1 ]; then
            mapfile -t all_vms < <(echo "${template_vms[@]}" "${standalone_vms[@]}")
        fi
        if [ -n "$only_update" ]; then
            IFS=, read -ra all_vms <<<"${only_update}"
        fi
        if [ "${#all_vms[*]}" -gt 0 ]; then
            for vm in ${all_vms[*]};
            do
                echo "----> Upgrading $vm..."
                if [ "$(qvm-volume info "$vm:root" revisions_to_keep)" == 0 ]; then
                    echo "WARNING: No snapshot backup history is setup (revisions_to_keep = 0). We cannot revert upgrade in case of any issue."
                    if [ "$assumeyes" != "1" ] && ! confirm "-> Continue?"; then
                        exit 1
                    fi
                fi
                qvm-run -q "$vm" "rm QubesIncoming/dom0/upgrade-template-standalone.sh" || true
                qvm-copy-to-vm "$vm" "$scriptsdir/upgrade-template-standalone.sh"
                exit_code=
                qvm-run -q -u root -p "$vm" "bash /home/user/QubesIncoming/dom0/upgrade-template-standalone.sh && rm -f /home/user/QubesIncoming/dom0/upgrade-template-standalone.sh" || exit_code=$?
                if [ -n "$exit_code" ]; then
                    case "$exit_code" in
                        2) 
                            echo "ERROR: Unsupported distribution for $vm."
                            ;;
                        3) 
                            echo "ERROR: An error occured during upgrade transaction for $vm."
                            ;;
                        *)
                            echo "ERROR: A general error occured while upgrading $vm (exit code $exit_code)."
                            ;;
                    esac
                    if [ "$assumeyes" != "1" ] && ! confirm "-> Continue?"; then
                        qvm-shutdown --wait "$vm"
                        qvm-volume revert "$vm":root
                        exit 1
                    fi
                fi
            done
        fi
        # Shutdown nonessential VMs again if some would have other NetVM than UpdateVM (e.g. sys-whonix)
        shutdown_nonessential_vms
    fi

    if [ "$release_upgrade" == "1" ]; then
        echo "---> (STAGE 3) Upgrading 'qubes-release' and 'python?-systemd'..."
        # shellcheck disable=SC2086
        qubes-dom0-update $dnf_opts --releasever=4.1 qubes-release 'python?-systemd'
        rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-32-primary
    fi

    if [ "$dist_upgrade" == "1" ]; then
        echo "---> (STAGE 4) Upgrading to QubesOS R4.1 and Fedora 32 repositories..."
        # xscreensaver remains unsuable while upgrading
        # it's impossible to unlock it due to PAM update
        echo "INFO: Xscreensaver has been killed. Desktop won't lock before next reboot."
        pkill xscreensaver || true

        # Install Audio and Gui daemons
        # it should be pulled by distro-sync
        # but better to ensure that
        packages="qubes-audio-daemon qubes-gui-daemon"

        # Install new Qubes Grub theme before not being able to
        # download anything else due to distro-sync
        packages="$packages grub2-qubes-theme qubes-artwork-plymouth"
        if is_qubes_uefi; then
            packages="$packages grub2-efi-x64"
        fi
        # shellcheck disable=SC2086
        qubes-dom0-update $dnf_opts --downloadonly $packages

        # Don't clean cache of previous transaction for the requested packages.
        # shellcheck disable=SC2086
        qubes-dom0-update ${dnf_opts_noclean} --downloadonly --action=distro-sync || exit_code=$?
        if [ -z "$exit_code" ] || [ "$exit_code" == 100 ]; then
            if [ "$assumeyes" == "1" ] || confirm "---> Shutdown all VM?"; then
                qvm-shutdown --wait --all

                # distro-sync phase
                if [ "$assumeyes" == 1 ]; then
                    dnf distro-sync -y --exclude="kernel-$(uname -r)" --best --allowerasing
                else
                    dnf distro-sync --exclude="kernel-$(uname -r)" --best --allowerasing
                fi

                # install requested packages
                for pkg in $packages
                do
                    pkg_rpm="$(ls /var/lib/qubes/updates/rpm/$pkg*.rpm)"
                    if [ -e "$pkg_rpm" ]; then
                        packages_rpm="$packages_rpm $pkg_rpm"
                    fi
                done

                if [ -n "$packages_rpm" ]; then
                    # shellcheck disable=SC2086
                    if [ "$assumeyes" == 1 ]; then
                        dnf install -y --best --allowerasing $packages_rpm
                    else
                        dnf install --best --allowerasing $packages_rpm
                    fi
                fi

                # Fix dbus to dbus-broker change
                systemctl enable dbus-broker

                # Preset selected other services
                systemctl preset qubes-qrexec-policy-daemon
                systemctl preset logrotate systemd-pstore

                # Update legacy Grub if needed
                update_legacy_grub
            else
                echo "WARNING: dist-upgrade stage canceled."
            fi
        else
            false
        fi
    fi

    if [ "$update_grub" == "1" ]; then
        echo "---> (STAGE 5) Installing EFI Grub..."
        setup_efi_grub
    fi
    echo "INFO: Please ensure to have completed all the stages and reboot before continuing."
fi
