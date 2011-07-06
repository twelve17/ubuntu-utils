#!/bin/bash

#-----------------------------------------------------------------------------
function removeKernel {
    local kversion=$1
    local allPackages=""
    for prefix in linux-image- linux-headers- linux-restricted-modules-;
    do 
        local package="${prefix}${kversion}"
        local instCount=`dpkg --list | grep -c $package`
        if [ "$instCount" == "1" ]; then
            allPackages="$allPackages $package"
            echo "adding $package to uninstall list"
        fi
    done
    allPackages=`echo $allPackages | sed 's/\(^\s*\)\([^\s\]\+\)\(\s*$\)/\2/'`
    if [ -n "$allPackages" ]; then
        sudo apt-get remove --purge $allPackages
    else
        echo "no packages to remove for version $kversion"
    fi
}


#-----------------------------------------------------------------------------
function listKernels {
    dpkg --list | grep linux-image | awk '{ print $2 }' | sed 's/linux-image-//' | grep -v '^generic$' | sort
}

#=============================================================================

KERNEL=$1
KERNEL=`echo $KERNEL | sed 's/linux-image-//'`

if [ -n "$KERNEL" ]; then
    if [ "$KERNEL" == `uname -r` ]; then
        echo "error: cannot remove currently running kernel: $KERNEL"
        exit 1
    fi
    removeKernel $KERNEL
else
    echo "usage: $0 {kernel_version}"

    echo "currently installed kernels:"
    echo
    listKernels
    exit 1
fi
