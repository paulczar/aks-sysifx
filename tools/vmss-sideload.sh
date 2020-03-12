#!/usr/bin/env bash
set -o errexit

if [ "$1" == "" ]; then
    echo "resource group required ([script] resource_group cluster_name)"
    exit 1
elif [ "$2" == "" ]; then
    echo "cluster name required ([script] resource_group cluster_name)"
    exit 1
fi

resource_group=$1
cluster_name=$2

scrurl="https://raw.githubusercontent.com/jnoller/k8s-io-debug/master/tools/sideload.sh"
cmd="\"curl ${scrurl} | sudo bash\""

nrg=$(az aks show --resource-group ${resource_group} --name ${cluster_name} --query nodeResourceGroup -o tsv)
scaleset=$(az vmss list --resource-group ${nrg} --query [0].name -o tsv)
nodes=$(az vmss list-instances -n ${scaleset} --resource-group ${nrg} --query [].name -o tsv)
node_ids=$(az vmss list-instances -n ${scaleset} --resource-group ${nrg} --query [].instanceId -o tsv)

while read line
do
  node=$line
  az vmss run-command invoke -g "${nrg}" -n "${scaleset}" --instance "${line}" \
    --command-id RunShellScript -o json --scripts @sideload.sh | jq -r '.value[].message' &
done <<< ${node_ids}
wait
