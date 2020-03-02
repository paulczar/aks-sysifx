#!/bin/bash

###############################################################################
# Install the IOVisor BCC tools suite
# https://iovisor.github.io/bcc/

if [[ ! -d "/usr/share/bcc/tools" ]]; then
    sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 4052245BD4284CDD
    echo "deb https://repo.iovisor.org/apt/$(lsb_release -cs) $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/iovisor.list
    sudo apt-get update
    sudo apt-get install -y bcc-tools libbcc-examples linux-headers-$(uname -r)
    echo "export PATH=$PATH:/usr/share/bcc/tools/" >> ~/.bashrc
else
    echo "bcc tools already installed, skipping"
fi

###############################################################################
# Install the ebpf exporter for prometheus
# https://github.com/cloudflare/ebpf_exporter

mkdir /tmp/scratch
( cd /tmp/scratch
    if [[ ! -f "/usr/local/bin/ebpf_exporter" ]]; then
        wget -c https://github.com/cloudflare/ebpf_exporter/releases/download/v1.2.2/ebpf_exporter-1.2.2.tar.gz
        tar -xzvf ebpf_exporter-1.2.2.tar.gz
        mv ebpf_exporter-1.2.2/ebpf_exporter /usr/local/bin
    fi
    if [[ ! -f "/etc/systemd/system/ebpf_exporter.service" ]]; then
        wget -c https://raw.githubusercontent.com/jnoller/k8s-io-debug/master/ebpf_exporter.service
        mv ebpf_exporter.service /etc/systemd/system/ebpf_exporter.service
        mkdir /etc/ebpf_exporter
        #################################################
        # Install the biolatency configuration (https://github.com/cloudflare/ebpf_exporter/blob/master/examples/bio.yaml)
        # See: https://github.com/cloudflare/ebpf_exporter#block-io-histograms-histograms
        wget -c https://raw.githubusercontent.com/cloudflare/ebpf_exporter/master/examples/bio.yaml
        mv bio.yaml /etc/ebpf_exporter/config.yaml
        #################################################
        # Should add error checking, but this ain't go.
        systemctl daemon-reload
        systemctl start ebpf_exporter
    fi
)
rm -rf /tmp/scratch

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
