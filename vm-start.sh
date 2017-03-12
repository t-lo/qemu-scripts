#!/bin/bash -ue
#
# 'vmscripts' low-level VM management scripts - VM starter
#
# Copyright © 2015, 2016, 2017 Thilo Fromm. Released under the terms of the GNU
#    GLP v3.
#
#    vmscripts is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    vmscripts is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with vmscripts. If not, see <http://www.gnu.org/licenses/>.#
#

vmscripts_prereq="inactive"

start_longopts="--writable --foreground --graphics --no-root --boot-iso"
start_shortopts="-w -f -g -n -b"

start_usage() {
    echo " Usage:"
    echo "  vm start <name> [optional arguments] - start VM <name>"
    echo
    echo "   [-w|--writable]      'mutable' mode - changes to disk image will persist."
    echo "   [-f|--foreground]    run in foreground (detach with 'CTRL+a d')"
    echo "   [-g|--graphics]      start with graphics (SDL out) enabled."
    echo "   [-n|--no-root]       don't run operations that require root."
    echo "   [-b|--boot-iso]      ISO image (CD/DVD) has boot priority."
}
# ----

grok_sudo() {
    local sudo=""
    local user="$(id -un)"
    [ "$user" != "root" ] && sudo=sudo

    echo "$sudo"
}
# ----

tune_kvm_module() {
    local modname=""
    local sudo=$(grok_sudo)

    grep -q 'vmx' /proc/cpuinfo && modname="kvm-intel"
    grep -q 'svm' /proc/cpuinfo && modname="kvm-amd"

    if [ -z "$modname" ] ; then
	    echo
        echo "Unable to determine virtualization hardware." 
        echo "Hardware virtualization support may not work."
        return
    fi

    lsmod | grep -q "${modname/-/_}" || {
        [ -n "$sudo" ] && {
            echo
            echo "Kernel module for hardware virtualization support is not loaded."
            echo "We'll try and load $modname via 'sudo'."
            echo "Please provide your password at the 'sudo' prompt, or hit"
            echo "CTRL+C to continue without HW virtualization support (not recommended)"
        }
        $sudo modprobe "$modname"
        echo "Kernel HW virtualization support enabled."
    }

    local sysfs="/sys/module/${modname/-/_}/parameters/nested"
    if [ ! -e "$sysfs" ] ; then
        echo
        echo "### NOTE: Nested virtualization not supported"
        echo
        return
    fi

    if [ "$(cat $sysfs)" != "Y" ] ; then
        [ -n "$sudo" ] && {
            echo
            echo "kvm currently does not have the 'nested' option enabled."
            echo "I'd like to enable it, but I need to 'sudo' for this."
            echo "You may abort this by pressing CTRL+C at the sudo prompt."
        }
        if ! $sudo rmmod $modname >/dev/null 2>&1 ; then return; fi
    	$sudo modprobe $modname nested=1
        echo "Kernel nested virtualization support enabled."
    fi
}
# ----

grok_qemu() {
    local qemu="`which qemu-system-x86_64 2>/dev/null`"
    [ -z "$qemu" ] && qemu="`which qemu-kvm 2>/dev/null`"
    [ -z "$qemu" ] && qemu="`which kvm 2>/dev/null`"
    echo "$qemu"
}
# ----

grok_free_port() {
    local ignored_ports="$@"
    local start=1024
    local p=""
    {   netstat -ntpl 2>/dev/null   \
            | sed -n 's/.* [0-9.]\+:\([0-9]\+\) .*/\1/p'
        seq $start 65535
        for p in $ignored_ports; do echo $p; done
    } | sort -n | grep -A 130000 1024 | uniq -u | head -1
}
# ----

grok_ports() {
    local hmp=$(grok_free_port)
    write_rtconf "vm_port_hmp" "$hmp"

    local acquired_ports="$hmp"
    local p=""
    local prev=""
    for p in $forward_ports; do
        [ -n "$prev" ] && echo -n "$prev,"
        local l=$(grok_free_port $acquired_ports)
        prev="hostfwd=::$l-:$p"
        acquired_ports="$acquired_ports $l"
        write_rtconf "vm_port_$p" "$l"
    done
    echo -n "$prev"
}
# ----

sanity() {
    # basic sanity
    [ -f "$vm_pidfile" ] && {
        kill -s 0 $(cat "$vm_pidfile" 2>/dev/null) 2>/dev/null \
            && die "VM $vm_name already running"
        rm -f "$vm_pidfile"
    }

    rm -f "$vm_rtconf"
}
# ----

check_netmode() {
    local noroot="$1"

    if [ "$netmode" != "hidden" ] ; then
        $noroot && \
           die "Need sudo/root to start VM '$vm_name' in net mode '$netmode'."
    fi
    return 0
}
# ----

qscript_from_dir() {
    local qscriptdir="$1"
    echo "$qscriptdir/qemu-$vm_name.sh"
}
# ----

write_qemu_script() {
    local qemu="$1"
    local gfx="$2"
    local cdrom="$3"
    local bootiso="$4"
    local immutable="$5"

    local boot_prio="cdn"
    [ "$bootiso" = "true" ] && boot_prio="dcn"

    local script=$(mktemp --suffix "$USER-qemu-$vm_name")
    chmod 700 "$script"

    local tapdev=""
    local networking=""
    if [ "$netmode" = "hidden" ] ; then
        networking="-net user,vlan=0,net=$net,hostname=$vm_name,$hostfwd"
    else
        tapdev="tap-$vm_name"
        networking="-net tap,vlan=0,ifname=\"$tapdev\",script=no,downscript=no"
    fi
 
cat >> "$script" <<EOF
#!/bin/bash -i

set -x

ip_forward_and_nat() {
    local onoff="\$1"
    local if_name="$tapdev"
    local gw_if=\$(route -n | awk '/^0.0.0.0/ { print \$8; }')

    if \$onoff; then
        [ -n "\$gw_if" ] &&                                      \\
            {   echo " NOTE: will NAT all connections going through \$gw_if"
                iptables --table nat --append POSTROUTING        \\
                                    --out-interface \$gw_if -j MASQUERADE; }
        iptables  --insert FORWARD --in-interface \${if_name}  -j ACCEPT
        sysctl -q -w net.ipv4.ip_forward=1
    else 
        [ -n "\$gw_if" ] && iptables --table nat --delete POSTROUTING     \\
                                        --out-interface \$gw_if -j MASQUERADE
        iptables  --delete FORWARD --in-interface \${if_name}  -j ACCEPT
    fi
}

prepare() {
    [ "$netmode" != "hidden" ] && {
        ip tuntap add dev $tapdev mode tap
        ip a a "$net" dev "$tapdev" 
        ip link set mtu 65521 dev "$tapdev" up
        ip_forward_and_nat true
    }
}

run() {
    # start qemu in background so we can detach the screen session
    $qemu                                                               \\
     -monitor telnet:127.0.0.1:$vm_port_hmp,server,nowait,nodelay       \\
     -pidfile "$vm_pidfile"                                             \\
     -m "$mem"                                                          \\
     -rtc base=utc                                                      \\
     -smp "$cpu"                                                        \\
     -cpu host                                                          \\
     $gfx                                                               \\
     -virtfs local,id="hostroot",path="/",security_model=none,mount_tag=hostroot,readonly \\
     -virtfs local,id="io",path="$vm_iodir",security_model=none,mount_tag=io \\
     -machine pc,accel=kvm                                              \\
     -net nic,model=virtio,vlan=0                                       \\
     $networking                                                        \\
     -boot $boot_prio                                                   \\
     -drive file=$vm_disk_image,if=virtio,index=0,media=disk,format=raw \\
     $cdrom                                                             \\
     $immutable &

    # detach if --foreground was not provided
    $detach && screen -d "$vm_screen_name"

    # bring back qemu
    fg
}

teardown() {
    [ "$netmode" != "hidden" ] && {
        ip_forward_and_nat false
        ip link set dev "$tapdev" down
        ip tuntap del "$tapdev" mode tap
    }
}

case "\$1" in
    prepare)  prepare;;
    run)      run;;
    teardown) teardown;;
    *) echo "vmscripts SCRIPT ERROR: unknown vm start action \"\$1\""
esac
EOF
    echo "$script"
}
# ----

vm_start() {
    # command line options
    local immutable="-snapshot"
    local gfx="-nographic"
    local detach="true"
    local noroot=false
    local bootiso=false

    sanity

    # command line flags
    local opts
    opts=$(getopt -o bwfgn -l "writable,foreground,graphics,no-root,boot-iso" \
                                                        -n "vm start" -- "$@")
    for o in $opts; do
        case $o in
            -w|--writable)    immutable="";;
            -f|--foreground)  detach="false";;
            -g|--graphics)    gfx="";;
            -r|--no-root)     noroot=true;;
            -b|--boot-iso)    bootiso=true;;
        esac
    done

    check_netmode "$noroot"
    $noroot || tune_kvm_module

    if [ -z "$immutable" ] ; then
        write_rtconf "vm_immutable" "false"
    else
        write_rtconf "vm_immutable" "true"
    fi

    if [ "$gfx" = "-nographic" ] ; then
        write_rtconf "vm_graphics" "true"
    else
        write_rtconf "vm_graphics" "false"
    fi

    local qemu="`grok_qemu`"
    [ -z "$qemu" ] && {
        echo "ERROR: qemu not found"; exit 1; }
    write_rtconf "vm_qemu" "$qemu" 

    local cdrom=""
    [ -e "$vm_iso_image" ] && {
        cdrom="-drive file=$vm_iso_image,if=ide,index=0,media=cdrom"
        write_rtconf "vm_iso_image" "$vm_iso_image" ; }

    # 'grok_ports' will also update runtime config, so we source it
    local hostfwd=`grok_ports`
    source "$vm_rtconf"

    local vm_screen_name="${vm_name}-vmscripts"
    write_rtconf vm_screen_name "$vm_screen_name"

    mkdir -p "$vm_iodir"
set -x
    # generate qemu script, grok network settings, and run qemu in a screen session
    local qscript=$(write_qemu_script "$qemu" "$gfx" "$cdrom" "$bootiso" "$immutable")

    screen -A -S "$vm_screen_name" \
        bash -c "
        set -x
        if [ \"$netmode\" != \"hidden\" ] ; then
            echo
            echo VM '$vm_name' uses network mode '$netmode'.
            echo
            echo SUDO may ask you for a password in order to configure VM networking.
            echo
            sudo \"$qscript\" prepare
            \"$qscript\" run
            sudo \"$qscript\" teardown
        else
            \"$qscript\" prepare
            \"$qscript\" run
            \"$qscript\" teardown
        fi
        read
        rm -f \"$vm_pidfile\" \"$vm_rtconf\" \"$qscript/\" ; "

    $detach && {
        echo "-------------------------------------------"
        echo " The VM $vm_name has been started and"
        echo " detached from this terminal. Run"
        echo "   vm attach $vm_name"
        echo " to attach to the VM serial terminal"
        echo ; }
    return 0
}
# ----

if [ `basename "$0"` = "vm-start.sh" ] ; then
    [ "${vm_tools_initialized-NO}" != "YES" ] && {
        exec $(which vm) "start" $@
        exit 1; }
    vm_start $@
else
    true
fi
