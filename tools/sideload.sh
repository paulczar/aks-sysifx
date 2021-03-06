#!/usr/bin/env bash
#
# Do not attempt this valid bash script to the vmss run_command ala:
# az vmss run-command invoke -g "${nrg}" -n "${scaleset}" --instance "${line}" \
#     --command-id RunShellScript -o json --scripts @tools/sideload.sh \
#     --parameters "force exonly" | jq -r '.value[].message' &
#
# The az cli and walinux agent both do string interpolation and the script is
# executed (via eval), using valid bash does not work with command line
# arguments either. Or bash arrays.
#
# https://github.com/Azure/azure-cli/issues/10400

# set -o errexit   # abort on nonzero exitstatus
# set -o nounset   # abort on unbound variable
# set -o pipefail  # dont hide errors within pipes

TMPD='/tmp/debug-sideload'
DISTRO=$(lsb_release -cs)
LLVM_VERSION="8"
bcc_ref="v0.12.0"
force=0

exists () {
    if [[ -e $1 ]]; then
        return 1
    fi
    return 0
}

chk () {
    force=$1
    fname=$2
    if [ "$force" -eq 1 ] || ! [ -e "$fname" ]; then
        return 1
    fi
    return 0
}

apt_base_install () {
    echo "============   installing base dependencies"
    apt-get update && apt-get install -y \
        bison \
        binutils-dev \
        flex \
        make \
        g++ \
        git \
        libelf-dev \
        zlib1g-dev \
        libiberty-dev \
        libbfd-dev \
        libedit-dev \
        clang-${LLVM_VERSION} \
        libclang-${LLVM_VERSION}-dev \
        libclang-common-${LLVM_VERSION}-dev \
        libclang1-${LLVM_VERSION} \
        llvm-${LLVM_VERSION} \
        llvm-${LLVM_VERSION}-dev \
        llvm-${LLVM_VERSION}-runtime \
        libllvm${LLVM_VERSION} \
        systemtap-sdt-dev \
        python \
        quilt \
        luajit \
        luajit-5.1-dev \
        apt-transport-https \
        libssl-dev
}

in_bcc () {
    if chk "$force" '/usr/local/include/bcc'; then
        return
    fi
    ###############################################################################
    # Install the IOVisor BCC tools suite
    # https://iovisor.github.io/bcc/
    #
    # Build from source to avoid bugs patched in the main source repository
    # the current deb files are out of date.

    # Thanks to @alexeldeib for letting me steal his:
    # https://github.com/alexeldeib/bpftrace-static/blob/master/Dockerfile
    #
    # Note compiling BCC from source takes awhile. Uncomment to use RPMs instead
    # FORCE_BCC_RPM=
    #
    # All bcc tools land in /usr/share/bcc/*

    echo "============   installing bpf exporter"

    echo "deb http://apt.llvm.org/${DISTRO}/ llvm-toolchain-$(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/llvm.list
    echo "deb-src http://apt.llvm.org/${DISTRO}/ llvm-toolchain-${DISTRO} main" | sudo tee /etc/apt/sources.list.d/llvm.list
    echo "deb http://apt.llvm.org/${DISTRO}/ llvm-toolchain-${DISTRO}-${LLVM_VERSION} main" | sudo tee /etc/apt/sources.list.d/llvm.list
    echo "deb-src http://apt.llvm.org/${DISTRO}/ llvm-toolchain-${DISTRO}-${LLVM_VERSION} main" | sudo tee /etc/apt/sources.list.d/llvm.list
    curl -L https://apt.llvm.org/llvm-snapshot.gpg.key | apt-key add -
    apt-get update && apt-get install -y curl gnupg

    apt_base_install


    cd ${TMPD} || exit

    git clone https://github.com/iovisor/bcc.git
    mkdir bcc/build
    (
        cd bcc/build || exit
        cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local ..
        make
        make install
        mkdir -p /usr/local/lib
        cp src/cc/libbcc.a /usr/local/lib/libbcc.a
        cp src/cc/libbcc-loader-static.a /usr/local/lib/libbcc-loader-static.a
        cp ./src/cc/libbcc_bpf.a /usr/local/lib/libbpf.a
    )
    rm -rf bcc
    echo "export PATH=$PATH:/usr/share/bcc/tools/" >> /root/.bashrc
}

compile_cmake () {
    echo "============   installing cmake"
    if chk "$force" '/usr/local/bin/cmake'; then
        return
    fi
    cd ${TMPD} || exit
    apt_base_install
    build=2
    version=3.16
    curl -OL https://cmake.org/files/v$version/cmake-$version.$build.tar.gz
    tar -xzvf cmake-$version.$build.tar.gz
    (
        cd cmake-$version.$build/ || exit
        ./bootstrap
        make -j$(nproc)
        make install
    )
    rm -rf cmake-$version.$build*

}

deb_bcc () {
    echo "============   installing bcc from deb"
    # Compiling bcc from source takes awhile - the bugs in upstream may or may
    # not impact the results of all tests, so defaulting to packages.
    sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 4052245BD4284CDD
    echo "deb https://repo.iovisor.org/apt/$(lsb_release -cs) $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/iovisor.list
    sudo apt-get update
    sudo apt-get install -y bcc-tools libbcc-examples linux-headers-$(uname -r)
    echo "export PATH=$PATH:/usr/share/bcc/tools/" >> /root/.bashrc
}


in_bpftrace () {
    if chk "$force" '/usr/local/bin/bpftrace'; then
        return
    fi
    echo "============   installing bpftrace"
    cd ${TMPD} || exit

    git clone https://github.com/iovisor/bpftrace.git
    mkdir bpftrace/build
    (
        cd bpftrace/build || exit
        cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
            -DWARNINGS_AS_ERRORS:BOOL=OFF \
            -DSTATIC_LINKING:BOOL=ON -DSTATIC_LIBC:BOOL=OFF \
            -DEMBED_LLVM:BOOL=ON -DEMBED_CLANG:BOOL=ON \
            -DEMBED_LIBCLANG_ONLY:BOOL=OFF \
            -DLLVM_VERSION=$LLVM_VERSION \
            -DCMAKE_CXX_FLAGS='-include /usr/local/include/bcc/compat/linux/bpf.h -D__LINUX_BPF_H__' ../
        make -j$(nproc) embedded_llvm
        make -j$(nproc) embedded_clang
        make -j$(nproc)
        make -j$(nproc) install
        strip --keep-symbol BEGIN_trigger /usr/local/bin/bpftrace
    )
    rm -rf bpftrace
}

in_bpfexporter () {
    if chk "$force" '/usr/local/bin/ebpf_exporter'; then
        return
    fi
    echo "============   installing bpf exporter"
    cd ${TMPD} || exit
    git clone https://github.com/cloudflare/ebpf_exporter.git
    (
        cd ebpf_exporter || exit
        make release-binaries
        mv release/ebpf_exporter-*/ebpf_exporter /usr/local/bin

        wget -c https://raw.githubusercontent.com/jnoller/k8s-io-debug/master/tools/ebpf_exporter.service
        mv ebpf_exporter.service /etc/systemd/system/ebpf_exporter.service
        mkdir -p /etc/ebpf_exporter

        #################################################
        # Install the biolatency configuration (https://github.com/cloudflare/ebpf_exporter/blob/master/examples/bio.yaml)
        # See: https://github.com/cloudflare/ebpf_exporter#block-io-histograms-histograms

        wget -c https://raw.githubusercontent.com/cloudflare/ebpf_exporter/master/examples/bio.yaml
        mv bio.yaml /etc/ebpf_exporter/config.yaml
        systemctl daemon-reload
        systemctl start ebpf_exporter
        systemctl status ebpf_exporter.service
    )
    rm -rf ebpf_exporter
}

tweak_oom () {
    ###############################################################################
    # Disable the OOMKiller, set panic on OOM
    #
    # This will ensure that if your worker nodes encounter OOM conditions, that
    # rather than arbitratily killing processes on the machine, it will force the
    # node to cleanly reboot and re-join the cluster. This will help with fail-over,
    # and other conditions.

    # https://kubernetes.io/docs/tasks/administer-cluster/out-of-resource/
    # https://sysdig.com/blog/troubleshoot-kubernetes-oom/
    # https://frankdenneman.nl/2018/11/15/kubernetes-swap-and-the-vmware-balloon-driver/

    # Recent versions of Kubernetes force the linux OOMKiller on so that the kubelet
    # can call it to force eviction on memory overcommits. This will result in any
    # pod, managed or otherwise, and process on the machine outside of the kernel to
    # be force-killed to save the node. We disable it, because that's terrible.

    # Todo list:
    #     Set panic on oom in sysctl.conf, running system
    #     inject systemd service to re-set and watch the sysctl.conf file and fix it
    #         (Due to the kublet always re-enabling it)
    #     reboot nodes for all changes to take effect
    return 0
}

bindmounts () {

    ###############################################################################
    # TBD: Install flamegraph collector / heatmap generator for IO latency
    # apt-get install -y git
    # git clone https://github.com/brendangregg/FlameGraph /flamegraph && chmod +x /flamegraph/*.pl
    # git clone https://github.com/brendangregg/HeatMap /heatmap && chmod +x /heatmap/*.pl
    # echo "export PATH=$PATH:/heatmap:/flamegraph" >> ~/.bashrc

    ###############################################################################
    # Remount docker and kublet if we see the on-disk token (cause I'm lazy)

    # /etc/waagent.conf controls where the /dev/sdb tempfs is mounted:
    #   ResourceDisk.MountPoint=/mnt
    # Also, the format, so I could tune this to xfs for the containers (TBD)
        # # File system on the resource disk
        # # Typically ext3 or ext4. FreeBSD images should use 'ufs2' here.
        # ResourceDisk.Filesystem=ext4

    # tempfs is mounted to /mnt - bindmount /var/lib/docker and /var/lib/kubelet to
    # /mnt/{daemon} and preserve the pathing so things like sploink work.
    # if [[ ! -F "/tmpfs-remount" ]]; then
    #     systemctl is-active --quiet docker || docker stop $(docker ps -a -q)
    #     systemctl is-active --quiet docker || systemctl stop docker
    #     systemctl is-active --quiet kubelet || systemctl stop kubelet
    # fi
    return 0
}

apply_host_tuning () {
    # Apply specific changes to the Linux host to improve performance and
    # reliability under operational load.

    # Tunings applied:
    # - Use noop scheduler (https://wiki.ubuntu.com/Kernel/Reference/IOSchedulers)
    #  - the noop scheduler delegates all storage scheduling to the underlying
    #    storage devices.
    # - sysctl changes:
    #   - set panic on oom / reboot on panic
    # /sys/block/sd*/queue/read_ahead_kb = 4096
    # /sys/block/sd*/queue/max_sectors_kb = 128
    # /sys/block/sd*/queue/scheduler = mq-deadline
    # /sys/block/sd[c-z]/device/queue_depth = 64

    return 0
}

print_usage () {
    printf "Usage: sideload.sh [-f][-b]"
}

error_exit () {
    if [ "$force" -eq 1 ]; then
        return
    fi
    echo "$1" 1>&2
    exit 1
}

main () {

    bcc_source=0
    force=0
    tune=0
    exonly=0
    remount=0
    npd=0
    options=()
    eoo=0

    while [[ $1 ]]; do
        if ! ((eoo)); then
            case "$1" in
                force)
                    force=1
                    shift
                    ;;
                source)
                    bcc_source=1
                    shift
                    ;;
                exonly)
                    exonly=1
                    shift
                    ;;
                --)
                    eoo=1
                    options+=("$1")
                    shift
                    ;;
                *)
                    options+=("$1")
                    shift
                    ;;
            esac
        else
            options+=("$1")
            shift
        fi
    done

    if [ -e ${TMPD} ]; then
        rm -rf ${TMPD}
    fi
    mkdir -p ${TMPD}

    compile_cmake || error_exit "Failed to install cmake"
    if [ $exonly -eq 1 ]; then
        in_bpfexporter || error_exit "Failed to install bpf exporter"
        exit
    else
        in_bpfexporter || error_exit "Failed to install bpf exporter"
    fi

    if [ $bcc_source -eq 1 ]; then
        in_bcc || error_exit "Failed to install bcc"
        in_bpftrace || error_exit "Failed to install bpftrace"
    else
        deb_bcc || error_exit "Failed to install bcc from apt"
    fi

    in_bpfexporter || error_exit "Failed to install bpf exporter"

    if [ $tune -eq 1 ]; then
        # Stub for system tunings to apply
        apply_host_tuning || "Failed to apply host tunables"
    fi
    rm -rf ${TMPD}
}

# Run things here.
main "${@}"
