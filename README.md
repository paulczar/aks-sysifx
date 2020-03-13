
# aks-sysifx

# Summary

This project provides tools and visualizations for AKS customers t


# Installation

OSX:
```shell

 brew install yq
 brew install helmfile
```

- Add the [platform-operations-on-kubernetes](https://github.com/paulczar/platform-operations-on-kubernetes) repository
  as a submodule in the `monitoring` directory:

```shell
git submodule add git@github.com:paulczar/platform-operations-on-kubernetes.git monitoring/platform-operations-on-kubernetes
```

Deploy bcc/bpf/dependencies on the worker nodes:

```
tools/vmss-sideload.sh Kubernaughty demo001
```

This script bypasses SSH by using the VMSS run command extension, if you've
blocked that on the RG for any reason this will fail. The executed script
is piped to sudo on every worker node and installs bcc and other required
tools.

Using the platform-operations-on-kubernetes directory:

```
. ../envs.sh && ./scripts/check-namespaces.sh -c -d && helmfile apply
```

This deploys a minimal prometheus / grafana stack along with the node exporter.

The dashboards/* directory is the source for all of the grafana visualizations.

## TODO:
5. NPD on host
