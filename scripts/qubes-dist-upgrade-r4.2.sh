#!/bin/bash

# Frédéric Pierret (fepitre) frederic.pierret@qubes-os.org

set -e
shopt -s nullglob
if [ "${VERBOSE:-0}" -ge 2 ] || [ "${DEBUG:-0}" -eq 1 ]; then
    set -x
fi

scriptsdir=/usr/lib/qubes

#-----------------------------------------------------------------------------#

usage() {
echo "

This script is used for updating current QubesOS R4.1 to R4.2.

Options:
    --update, -t                       (STAGE 1) Update of dom0, TemplatesVM and StandaloneVM.
    --release-upgrade, -r              (STAGE 2) Update 'qubes-release' for Qubes R4.2.
    --dist-upgrade, -s                 (STAGE 3) Upgrade to Qubes R4.2 and Fedora 37 repositories.
    --template-standalone-upgrade, -l  (STAGE 4) Upgrade templates and standalone VMs to R4.2 repository.
    --finalize, -x                     (STAGE 5) Finalize upgrade. It does:
                                         - resync applications and features
                                         - cleanup salt states
    --convert-policy, -p               (STAGE 6) Convert qrexec policy in /etc/qubes-rpc/policy
                                       to the new format in /etc/qubes/policy.d.
    --all-pre-reboot                   Execute stages 1 to 3
    --all-post-reboot                  Execute stages 4 to 6

    --assumeyes, -y                    Automatically answer yes for all questions.
    --usbvm, -u                        Current UsbVM defined (default 'sys-usb').
    --netvm, -n                        Current NetVM defined (default 'sys-net').
    --updatevm, -f                     Current UpdateVM defined (default 'sys-firewall').
    --skip-template-upgrade, -j        Don't upgrade TemplateVM to R4.2 repositories.
    --skip-standalone-upgrade, -k      Don't upgrade StandaloneVM to R4.2 repositories.
    --only-update                      Apply STAGE 4 and resync appmenus only to
                                       selected qubes (comma separated list).
    --keep-running                     List of extra VMs to keep running during update (comma separated list).
                                       Can be useful if multiple updates proxy VMs are configured.
    --max-concurrency                  How many TemplateVM/StandaloneVM to update in parallel in STAGE 1
                                       (default 4).
"

    exit 1
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

update_prechecks() {
    echo "INFO: Please wait while running pre-checks..."
    if qvm-check -q "$updatevm" 2>/dev/null; then
        if ! qvm-run -q "$updatevm" "command -v dnf"; then
           echo "ERROR: UpdateVM ($updatevm) should on a template that have 'dnf' installed - at least Fedora 37, Debian 11, or Whonix 16."
           exit 1
        fi
    fi
}

shutdown_nonessential_vms() {

    if ! systemctl is-active -q qubesd.service; then
        # qubesd not running anymore in later upgrade stages
        return
    fi
    mapfile -t running_vms < <(qvm-ls --running --raw-list --fields name)
    keep_running=( dom0 "$usbvm" "$netvm" "$updatevm" "${extra_keep_running[@]}" )
    # all the updates-proxy targets
    if [ -e "/etc/qubes-rpc/policy/qubes.UpdatesProxy" ]; then
        mapfile -t updates_proxy < <(grep '^\s*[^#].*target=' /etc/qubes-rpc/policy/qubes.UpdatesProxy | cut -d = -f 2)
        keep_running+=( "${updates_proxy[@]}" )
    fi
    if [ -e "/etc/qubes/policy.d" ]; then
      mapfile -t updates_proxy_new < <(grep qubes.UpdatesProxy /etc/qubes/policy.d/*.policy | grep '^\s*[^#].*target=' | cut -d = -f 2)
      keep_running+=( "${updates_proxy_new[@]}" )
    fi

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
        if [ "$assumeyes" == "1" ] || confirm "---> Allow shutdown of unnecessary VM (use --keep-running to exclude some): ${running_vms[*]}?"; then
            qvm-shutdown --wait "${running_vms[@]}"
        else
            exit 0
        fi
    fi
}

get_root_volume_name() {
    local root_dev root_volume
    root_dev=$(df --output=source / | tail -1)
    case "$root_dev" in (/dev/mapper/*) ;; (*) return;; esac
    root_volume=$(lvs --no-headings --separator=/ -o vg_name,lv_name "$root_dev" | tr -d ' ')
    case "$root_volume" in (*/) return;; esac
    echo "$root_volume"
}

get_root_group_name() {
    local root_dev root_volume
    root_dev=$(df --output=source / | tail -1)
    case "$root_dev" in (/dev/mapper/*) ;; (*) return;; esac
    root_group=$(lvs --no-headings -o vg_name "$root_dev" | tr -d ' ')
    echo "$root_group"
}

get_volume_type() {
    lvs --noheadings --options lv_layout "$1" | tr -d ' '
}

# restore legacy policy from .rpmsave files, to not change the policy semantics
restore_rpmsave_policy() {
    local orig_policy_rpmsave_files=( "$@" )
    for policy_file in /etc/qubes-rpc/policy/*.rpmsave; do
        # this works because policy filenames do not have spaces
        if ! [[ "${orig_policy_rpmsave_files[*]}" == *" $policy_file "* ]]; then
            mv "${policy_file}" "${policy_file%.rpmsave}"
        fi
    done
}

has_updated_qubes_version() {
    grep -q 'VERSION_ID=4.2' /etc/os-release
}

#-----------------------------------------------------------------------------#

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run with root permissions"
   exit 1
fi

if ! OPTS=$(getopt -o trslxyu:n:f:jkp --long releasever:,help,update,release-upgrade,dist-upgrade,template-standalone-upgrade,finalize,convert-policy,all-pre-reboot,all-post-reboot,assumeyes,usbvm:,netvm:,updatevm:,skip-template-upgrade,skip-standalone-upgrade,only-update:,max-concurrency:,keep-running: -n "$0" -- "$@"); then
    echo "ERROR: Failed while parsing options."
    exit 1
fi

eval set -- "$OPTS"

# Common DNF options
dnf_opts_noclean='--best --allowerasing'
extra_keep_running=()
convert_policy=

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help) usage ;;
        --releasever)
            if [ "$2" != "4.2" ]; then
                echo "Unsupported --releasever" >&2
                exit 1
            fi
            shift
            ;;
        --all-pre-reboot)
            update=1
            release_upgrade=1
            dist_upgrade=1
            ;;
        --all-post-reboot)
            template_standalone_upgrade=1
            finalize=1
            convert_policy=1
            ;;
        -t | --update ) update=1;;
        -l | --template-standalone-upgrade) template_standalone_upgrade=1;;
        -r | --release-upgrade) release_upgrade=1;;
        -s | --dist-upgrade ) dist_upgrade=1;;
        -y | --assumeyes ) assumeyes=1;;
        -u | --usbvm ) usbvm="$2"; shift ;;
        -n | --netvm ) netvm="$2"; shift ;;
        -f | --updatevm ) updatevm="$2"; shift ;;
        --only-update) only_update="$2"; shift ;;
        --keep-running) IFS=, read -ra extra_keep_running <<<"$2"; shift ;;
        --max-concurrency) max_concurrency="$2"; shift ;;
        -j | --skip-template-upgrade ) skip_template_upgrade=1;;
        -k | --skip-standalone-upgrade ) skip_standalone_upgrade=1;;
        -x | --finalize ) finalize=1;;
        -p | --convert-policy ) convert_policy=1;;
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
if [ -z "${updatevm-}" ]; then
    # don't worry if getting updatevm fails - if qubes-prefs doesn't work
    # anymore, updatevm is useless too (it's used via qubes-dom0-update which
    # checks for that independently)
    updatevm=$(qubes-prefs updatevm 2>/dev/null || :)
fi
max_concurrency="${max_concurrency:-4}"

# Run prechecks first
update_prechecks

# Automatically add qubes providing dom0 input devices to remain powered on
if which xinput > /dev/null; then
    read -r -a xinput_qubes <<< "$(xinput list --name-only | sed -n 's/\(^[a-zA-Z][a-zA-Z0-9_-]*\):.*$/\1/p')"
    for qube in "${xinput_qubes[@]}"
    do
        if qvm-check -q "$qube"; then
            echo "INFO: Found $qube providing input devices. It will be kept running."
            extra_keep_running+=( "$qube" )
        fi
    done
else
    echo "WARNING: Unable to detect qubes providing input devices. PLease provide them using --keep-running option."
fi

# shellcheck disable=SC1003
echo 'WARNING: /!\ MAKE SURE YOU HAVE MADE A BACKUP OF ALL YOUR VMs AND dom0 DATA /!\'
if [ "$assumeyes" == "1" ] || confirm "-> Launch upgrade process?"; then
    # Shutdown nonessential VMs
    shutdown_nonessential_vms

    if [ "$update" = "1" ] && [ "$(rpm -q --qf='%{VERSION}' qubes-release)" = "4.2" ]; then
        echo "---> (STAGE 1) Updating dom0... already done, skipping"
        update=
    fi

    if [ "$update" == "1" ]; then
      root_vol_name=$(get_root_volume_name)
      root_group_name=$(get_root_group_name)
      if [ -z "$root_vol_name" ]; then
        echo "---> (STAGE 1) Skipping dom0 snapshot - no LVM volume found"
      elif [ "$(get_volume_type "$root_vol_name")" != "thin,sparse" ] ; then
        echo "---> (STAGE 1) Skipping dom0 snapshot - no not a thin volume"
      elif lvs "$root_group_name/Qubes41UpgradeBackup" > /dev/null 2>&1 ; then
        echo "---> (STAGE 1) Skipping dom0 snapshot - snapshot already exists. If you want to make a snapshot anyway, remove the existing one using lvremove $root_group_name/Qubes41UpgradeBackup"
      elif [ "$assumeyes" == "1" ] || confirm "---> (STAGE 1) Do you want to make a dom0 snapshot?"; then
        # make a dom0 snapshot
        lvcreate -n Qubes41UpgradeBackup -s "$root_vol_name"
        echo "--> If upgrade to 4.2 fails, you can restore your dom0 snapshot with sudo lvconvert --merge $root_group_name/Qubes41UpgradeBackup. Reboot after restoration."
      fi

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
            if [ "$skip_template_upgrade" != 1 ]; then
                qubesctl --skip-dom0 --max-concurrency="$max_concurrency" \
                    --templates state.sls update.qubes-vm
            fi
            if [ "$skip_standalone_upgrade" != 1 ]; then
                qubesctl --skip-dom0 --max-concurrency="$max_concurrency" \
                    --standalones state.sls update.qubes-vm
            fi
        fi

        # Shutdown nonessential VMs again if some would have other NetVM than UpdateVM (e.g. sys-whonix)
        shutdown_nonessential_vms

        # Restart UpdateVM with updated templates (several fixes)
        qvm-shutdown --wait --force "$updatevm"
        qvm-start "$updatevm"
    fi

    if [ "$release_upgrade" == "1" ]; then
        echo "---> (STAGE 2) Upgrading 'qubes-release'..."
        # shellcheck disable=SC2086
        if ! rpm -q google-noto-sans-fonts google-noto-serif-fonts >/dev/null; then
            qubes-dom0-update $dnf_opts google-noto-sans-fonts google-noto-serif-fonts
        fi
        rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-qubes-4.2-primary
        if [ "$(rpm -q --qf='%{VERSION}' qubes-release)" != "4.2" ]; then
            qubes-dom0-update $dnf_opts --action=update --releasever=4.2 qubes-release
        fi
        rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-37-primary
        if ! grep -q fc37 /etc/yum.repos.d/qubes-dom0.repo; then
            echo "WARNING: /etc/yum.repos.d/qubes-dom0.repo is not updated to R4.2 version"
            if [ -f /etc/yum.repos.d/qubes-dom0.repo ] && \
                    grep -q fc37 /etc/yum.repos.d/qubes-dom0.repo.rpmnew; then
                echo "INFO: Found R4.2 repositories in /etc/yum.repos.d/qubes-dom0.repo.rpmnew"
                if [ "$assumeyes" == "1" ] || confirm "---> Replace qubes-dom0.repo with qubes-dom0.repo.rpmnew?"; then
                    mv --backup=simple --suffix=.bak /etc/yum.repos.d/qubes-dom0.repo.rpmnew \
                                /etc/yum.repos.d/qubes-dom0.repo
                    echo "INFO: Old /etc/yum.repos.d/qubes-dom0.repo saved with .bak extension"
                fi
            fi
        fi
    fi

    if [ "$dist_upgrade" == "1" ]; then
        echo "---> (STAGE 3) Upgrading to QubesOS R4.2 and Fedora 37 repositories..."
        # xscreensaver remains unsuable while upgrading
        # it's impossible to unlock it due to PAM update
        echo "INFO: Xscreensaver has been killed. Desktop won't lock before next reboot."
        pkill xscreensaver || true

        # Don't clean cache of previous transaction for the requested packages.
        # shellcheck disable=SC2086
        qubes-dom0-update ${dnf_opts_noclean} --downloadonly --force-xen-upgrade --action=distro-sync || exit_code=$?
        if [ -z "$exit_code" ] || [ "$exit_code" == 100 ]; then
            if [ "$assumeyes" == "1" ] || confirm "---> Shutdown all qubes (requested keep running and input devices qubes will remain powered on)?"; then
                qvm_shutdown_exclude=()
                for qube in "${extra_keep_running[@]}"; do
                    qvm_shutdown_exclude+=("--exclude=$qube")
                done
                qvm-shutdown --wait --all "${qvm_shutdown_exclude[@]}"

                rpmsave_policy_files_before=( "/etc/qubes-rpc/policy/"*.rpmsave )
                update_ret=0
                # distro-sync phase
                if [ "$assumeyes" == 1 ]; then
                    dnf distro-sync -y --exclude="kernel-$(uname -r)" --best --allowerasing || update_ret=$?
                else
                    dnf distro-sync --exclude="kernel-$(uname -r)" --best --allowerasing || update_ret=$?
                fi
                # fixup the policy regardless of the result
                restore_rpmsave_policy "${rpmsave_policy_files_before[@]}"

                if [ "$update_ret" -ne 0 ]; then
                    exit "$update_ret"
                fi

            else
                echo "WARNING: dist-upgrade stage canceled."
            fi
        else
            false
        fi
        echo "INFO: Please ensure you have completed stages 1, 2 and 3 and reboot before continuing."
    fi

    if { [ "$template_standalone_upgrade" == 1 ] || [ "$finalize" == 1 ]; } && ! has_updated_qubes_version; then
        echo "ERROR: Cannot continue to STAGE 4, dom0 is not R4.2 yet. Any error happened in previous stages?"
        exit 1
    fi

    if [ "$template_standalone_upgrade" == 1 ]; then
        echo "---> (STAGE 4) Upgrade templates and standalone VMs to R4.2 repository..."
        if [ "$skip_template_upgrade" != 1 ]; then
            mapfile -t template_vms < <(qvm-ls --raw-data --fields name,klass | grep 'TemplateVM$' | cut -d '|' -f 1)
        fi
        if [ "$skip_standalone_upgrade" != 1 ]; then
            mapfile -t standalone_vms < <(qvm-ls --raw-data --fields name,klass | grep 'StandaloneVM$' | cut -d '|' -f 1)
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
                qvm-shutdown --wait "$vm"
                if [ -n "$exit_code" ]; then
                    case "$exit_code" in
                        2)
                            echo "ERROR: Unsupported distribution for $vm."
                            echo "It may still work under R4.2 but it will not get new features, nor important updates (including security fixes)."
                            echo "Consider switching to supported distribution - see https:///www.qubes-os.org/doc/supported-releases/"
                            ;;
                        3)
                            echo "ERROR: An error occurred during upgrade transaction for $vm."
                            ;;
                        *)
                            echo "ERROR: A general error occurred while upgrading $vm (exit code $exit_code)."
                            ;;
                    esac
                    if [ "$assumeyes" != "1" ] && ! confirm "-> Continue?"; then
                        echo "REVERTING template to pre-ugrade state"
                        qvm-volume revert "$vm":root
                        exit 1
                    fi
                fi
            done
        fi
        # Shutdown nonessential VMs again if some would have other NetVM than UpdateVM (e.g. sys-whonix)
        shutdown_nonessential_vms
    fi

    # Executing post upgrade tasks
  if [ "$finalize" == 1 ]; then
      echo "---> (STAGE 5) Synchronizing menu entries and supported features"
      if [ "$skip_template_upgrade" != 1 ]; then
          mapfile -t template_vms < <(qvm-ls --raw-data --fields name,klass | grep 'TemplateVM$' | cut -d '|' -f 1)
      fi
      if [ "$skip_standalone_upgrade" != 1 ]; then
          mapfile -t standalone_vms < <(qvm-ls --raw-data --fields name,klass | grep 'StandaloneVM$' | cut -d '|' -f 1)
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
      user=$(groupmems -l -g qubes | cut -f 1 -d ' ')
      runuser -u "$user" -- qvm-appmenus --all --update

      echo "---> (STAGE 5) Cleaning up salt"
      echo "Error on ext_pillar interface qvm_prefs is expected"
      qubesctl saltutil.clear_cache
      qubesctl saltutil.sync_all

      echo "---> (STAGE 5) Adjusting default kernel"
      default_kernel="$(qubes-prefs default-kernel)"
      default_kernel_path="/var/lib/qubes/vm-kernels/$default_kernel"
      default_kernel_package="$(rpm --qf '%{NAME}' -qf "$default_kernel_path")"
      if [ "$default_kernel_package" = "kernel-qubes-vm" ]; then
          new_kernel=$(rpm -q --qf '%{VERSION}-%{RELEASE}\n'  kernel-qubes-vm | sort -V | tail -1)
          new_kernel="${new_kernel/.qubes/}"
          if ! [ -e "/var/lib/qubes/vm-kernels/$new_kernel" ]; then
              echo "ERROR: Kernel $new_kernel installed but /var/lib/qubes/vm-kernels/$new_kernel is missing!"
              exit 1
          fi
          echo "Changing default kernel from $default_kernel to $new_kernel"
          qubes-prefs default-kernel "$new_kernel"
      fi

      root_vol_name=$(get_root_volume_name)
      if [ "$root_vol_name" ]; then
        root_group_name=$(get_root_group_name)
        if lvs "$root_group_name/Qubes41UpgradeBackup" > /dev/null 2>&1; then
          if [ "$assumeyes" == "1" ]; then
            lvremove -f "$root_group_name/Qubes41UpgradeBackup"
          else
            lvremove "$root_group_name/Qubes41UpgradeBackup"
          fi
        fi
      fi
  fi

  if [ "$convert_policy" == 1 ]; then
    echo "---> (STAGE 6) Convert qrexec policy to the new format, it may take several minutes"
    # R4.1 used to have user=root in qubes.Input* policies, which in fact never
    # worked (was ignored) and was removed later
    for policy in /etc/qubes-rpc/policy/qubes.InputMouse \
                  /etc/qubes-rpc/policy/qubes.InputKeyboard \
                  /etc/qubes-rpc/policy/qubes.InputTablet; do
        if [ -r "$policy" ]; then
            sed -i 's/,user=root//' "$policy"
        fi
    done
    qrexec-legacy-convert
  fi
fi
