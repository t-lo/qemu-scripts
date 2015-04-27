#!/bin/bash -ue
#
# 'vmscripts' low-level VM management scripts - VM starter
#
# Copyright © 2015 Thilo Fromm. Released under the terms of the GNU GLP v3.
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

tune_kvm_module() {
    local modname=""

    local sudo=""
    local user="$(id -un)"
    [ "$user" != "root" ] && sudo=sudo

    grep -q 'vmx' /proc/cpuinfo && modname="kvm-intel"
    grep -q 'svm' /proc/cpuinfo && modname="kvm-amd"

    if [ -z "$modname" ] ; then
        echo "Unable to determine virtualization hardware." 
        echo "Nested virtualization may not work."
        return
    fi

    local sysfs="/sys/module/${modname/-/_}/parameters/nested"
    if [ "$(cat $sysfs)" != "Y" ] ; then
        echo
        echo "kvm currently does not have the 'nested' option enabled."
        echo "I'd like to enable it, but I need to 'sudo' for this."
        echo "You may abort this by pressing CTRL+C at the sudo prompt."
        $sudo rmmod $modname >/dev/null 2>&1 \
            && $sudo modprobe $modname nested=1
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

usage() {
    echo
    echo " vm start: Illegal argument encountered."
    echo " $@"
    echo
    echo " Usage:"
    echo "    vm start [rw|bg|gfx] <vm-name>"
    echo
    exit 1
}
# ----

sanity() {
    # basic sanity
    [ -z "$vm_name" ] && usage "The vm-name argument is missing."

    [ -f "$vm_pidfile" ] && {
        kill -s 0 $(cat "$vm_pidfile" 2>/dev/null) 2>/dev/null \
            && die "VM $vm_name already running"
        rm -f "$vm_pidfile"
    }
    rm -f "$vm_rtconf"
}
# ----

vm_start() {
    # command line options
    local immutable="-snapshot"
    local nogfx="-nographic"
    local detach=""

    sanity

    # command line flags
    if echo "$@" | grep -q "rw" ; then
        echo
        echo "The VM image will be *mutable*, all changes will persist."
        echo
        immutable=""
        write_rtconf "vm_immutable" "false"
    else
        write_rtconf "vm_immutable" "true"
    fi

    echo "$@" | grep -q "bg" && detach="-d -m"

    if echo "$@" | grep -q "gfx" ; then
        nogfx=""
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

    tune_kvm_module

    # will also update runtime config
    local hostfwd=`grok_ports`
    source "$vm_rtconf"

    local vm_screen_name="${vm_name}-vmscripts"
    write_rtconf vm_screen_name "$vm_screen_name"
    screen $detach -A -S "$vm_screen_name" \
        bash -c "
            $qemu                                                                   \
                -monitor telnet:127.0.0.1:$vm_port_hmp,server,nowait,nodelay        \
                -pidfile \"$vm_pidfile\"                                            \
                -m \"$mem\"                                                         \
                -rtc base=utc                                                       \
                -smp \"$cpu\"                                                       \
                -cpu host                                                           \
                $nogfx                                                              \
                -virtfs local,id=\"export\",path=\"$vm_export_dir\",security_model=none,mount_tag=export \
                -machine pc,accel=kvm                                               \
                -net nic,model=virtio,vlan=0                                        \
                -net user,vlan=0,net=$net,hostname=$vm_name,$hostfwd                \
                -boot cdn                                                           \
                -drive file=$vm_disk_image,if=virtio,index=0,media=disk             \
                $cdrom                                                              \
                $immutable ;
            rm -f \"$vm_pidfile\" \"$vm_rtconf\" ; "

    [ "$detach" != "" ] && {
        echo "-------------------------------------------"
        echo " The VM $vm_name has been started and"
        echo " detached from this terminal. Run"
        echo "   vm attach $vm_name"
        echo " to attach to the VM serial terminal"
        echo ; }
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
