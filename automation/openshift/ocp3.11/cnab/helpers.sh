#!/usr/bin/env bash
set -euo pipefail

az_login() {  # Logs into the Azure CLI, setting cloud and subscription according to configuration.
  if [ "${ENVIRONMENT}" == "AZUREUSGOVERNMENTCLOUD" ]; then
    az cloud set --name AzureUSGovernment
  fi
  az login --service-principal --username ${AZURE_CLIENT_ID} --password ${AZURE_CLIENT_SECRET} --tenant ${AZURE_TENANT_ID}
  az account set -s ${AZURE_SUBSCRIPTION_ID}
}

deploy_network() {
  masterlbName=${RESOURCE_PREFIX}-masterlb
  infralbName=${RESOURCE_PREFIX}-infralb

  # VNet & subnets
  az network vnet create -g ${RESOURCE_GROUP} -n ${VIRTUAL_NETWORK} \
      --address-prefix 10.12.0.0/16
  
  az network vnet subnet create -g ${RESOURCE_GROUP} -n master \
      --address-prefix 10.12.101.0/24 \
      --vnet-name ${VIRTUAL_NETWORK}

  az network vnet subnet create -g ${RESOURCE_GROUP} -n nodes \
      --address-prefix 10.12.102.0/24 \
      --vnet-name ${VIRTUAL_NETWORK}

  # Load balancers
  if [ ${USE_PUBLIC_IPS} == 'true' ]; then
    parallel 'az network public-ip create -g ${RESOURCE_GROUP} -n {}' ::: \
      ${masterlbName}-ip ${infralbName}-ip

    parallel 'az network lb create -g ${RESOURCE_GROUP} -n {} \
        --backend-pool-name loadBalancerBackEnd \
        --public-ip-address {}-ip' ::: \
        ${masterlbName} ${infralbName}
  else
    parallel 'az network lb create -g ${RESOURCE_GROUP} -n {} \
        --backend-pool-name loadBalancerBackEnd \
        --public-ip-address "" \
        --private-ip-address {}' ::: \
        ${MASTER_LB_PRIVATE_IP} ${INFRA_LB_PRIVATE_IP}
  fi

  # TODO: Only include CNS when CNS is enabled
  parallel 'az network nsg create -g ${RESOURCE_GROUP} -n {}' ::: \
    ${RESOURCE_PREFIX}-bastion-nsg ${RESOURCE_PREFIX}-cns-nsg ${RESOURCE_PREFIX}-master-nsg \
    ${RESOURCE_PREFIX}-infrastructure-nsg ${RESOURCE_PREFIX}-node-nsg

  parallel 'az network lb probe create -g ${RESOURCE_GROUP} -n httpsProbe \
          --lb-name {} --port 443 --protocol tcp' ::: \
          ${masterlbName} ${infralbName}
  parallel 'az network lb probe create -g ${RESOURCE_GROUP} -n httpProbe \
          --lb-name {} --port 80 --protocol tcp' ::: \
          ${infralbName}

  # Load balancer rules
  az network lb rule create -g ${RESOURCE_GROUP} -n OpenShiftAdminConsole \
      --lb-name ${masterlbName} --probe-name httpsProbe --protocol tcp \
      --frontend-port 443 --backend-port 443 --backend-pool-name loadBalancerBackEnd \
      --load-distribution SourceIP --idle-timeout 30

  az network lb rule create -g ${RESOURCE_GROUP} -n OpenShiftRouterHTTPS \
      --lb-name ${infralbName} --probe-name httpsProbe --protocol tcp \
      --frontend-port 443 --backend-port 443 --backend-pool-name loadBalancerBackEnd \
      --load-distribution SourceIP --idle-timeout 30
  az network lb rule create -g ${RESOURCE_GROUP} -n OpenShiftRouterHTTP \
      --lb-name ${infralbName} --probe-name httpProbe --protocol tcp \
      --frontend-port 80 --backend-port 80 --backend-pool-name loadBalancerBackEnd \
      --load-distribution SourceIP --idle-timeout 30

  # NSG rules
  az network nsg rule create -g ${RESOURCE_GROUP} -n ssh --nsg-name ${RESOURCE_PREFIX}-bastion-nsg \
      --priority 100 --access Allow --direction Inbound --protocol Tcp \
      --destination-address-prefixes '*' --source-address-prefixes '*' \
      --destination-port-ranges 22 --source-port-ranges '*'  # TODO: Check to make sure opening this is correct...

  az network nsg rule create -g ${RESOURCE_GROUP} -n https --nsg-name ${RESOURCE_PREFIX}-infrastructure-nsg \
      --priority 200 --access Allow --direction Inbound --protocol Tcp \
      --destination-address-prefixes '*' --source-address-prefixes '*' \
      --destination-port-ranges 443 --source-port-ranges '*'
  az network nsg rule create -g ${RESOURCE_GROUP} -n http --nsg-name ${RESOURCE_PREFIX}-infrastructure-nsg \
      --priority 300 --access Allow --direction Inbound --protocol Tcp \
      --destination-address-prefixes '*' --source-address-prefixes '*' \
      --destination-port-ranges 80 --source-port-ranges '*'

  az network nsg rule create -g ${RESOURCE_GROUP} -n https --nsg-name ${RESOURCE_PREFIX}-master-nsg \
      --priority 200 --access Allow --direction Inbound --protocol Tcp \
      --destination-address-prefixes '*' --source-address-prefixes '*' \
      --destination-port-ranges 443 --source-port-ranges '*'

  az network nsg rule create -g ${RESOURCE_GROUP} -n https --nsg-name ${RESOURCE_PREFIX}-node-nsg \
      --priority 200 --access Allow --direction Inbound --protocol Tcp \
      --destination-address-prefixes '*' --source-address-prefixes '*' \
      --destination-port-ranges 443 --source-port-ranges '*'
  az network nsg rule create -g ${RESOURCE_GROUP} -n http --nsg-name ${RESOURCE_PREFIX}-node-nsg \
      --priority 300 --access Allow --direction Inbound --protocol Tcp \
      --destination-address-prefixes '*' --source-address-prefixes '*' \
      --destination-port-ranges 80 --source-port-ranges '*'
}

deploy_storage() {
  parallel 'az storage account create -g ${RESOURCE_GROUP} -n {}' ::: \
    ${RESOURCE_PREFIX}diag ${RESOURCE_PREFIX}registry
}

deploy_vms() {
  fault_domain_count=2
  update_domain_count=0

  parallel 'az vm availability-set create -g ${RESOURCE_GROUP} -n {} \
      --platform-fault-domain-count 2' ::: \
      ${RESOURCE_PREFIX}-master-as ${RESOURCE_PREFIX}-infra-as \
      ${RESOURCE_PREFIX}-node-as ${RESOURCE_PREFIX}-cns-as
 
}


# Call the requested function and pass the arguments as-is
"$@"
