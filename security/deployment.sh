#Pre-req
- Azure cli
- az extension add -n azure-firewall

# Define Variables
RG=resourcegroupak
FW_NAME=aks-fw # Firewall Name
LOCATION=westeurope # Location 
HUB_VNET_NAME=hub-vnet # The Hub VNET where the Firewall, WAF, and Jump Box would reside
HUB_VNET_CIDR=192.168.0.0/19 
FW_SUBNET_NAME=AzureFirewallSubnet  ####DO NOT CHANGE THE NAME OF THIS SUBNET, this is a requirement for AZ FIREWALL 
FW_SUBNET_PREFIX=192.168.0.0/26
FWROUTE_TABLE_NAME=fw-route # the route table and the route entry to route traffic to the firewall
FWROUTE_NAME=route-all-to-fw

MGMT_SUBNET_NAME=hub-mgmt-subnet  #the subnet where our Jump Box will reside
MGMT_SUBNET_PREFIX=192.168.1.0/24

WAF_SUBNET_NAME=hub-waf-subnet #the subnet where Application Gateway will reside along with the IP and Name
WAF_SUBNET_PREFIX=192.168.2.0/26
APPGW_NAME=hub_appgw
APPGW_PIP_NAME=appgwpip

FW_PUBLIC_IP_NAME=hub-fw-pip #the firewall IP and Config Name
FW_CONFIG_NAME=SECURE_AKS_CONFIG

AKS_VNET_NAME=aks-vnet # The VNET where AKS will reside
AKS_CLUSTER_NAME=k8s-akhamessi # name of the cluster
AKS_VNET_CIDR=192.168.32.0/19 
AKS_NODES_SUBNET_NAME=aks-default-subnet # the AKS nodes subnet
AKS_NODES_SUBNET_PREFIX=192.168.32.0/23
AKS_INGRESS_SUBNET_NAME=aks-ingress-subnet #the AKS ingress subnet 
AKS_INGRESS_SUBNET_PREFIX=192.168.34.0/27

###create RG
$ az group create --name $RG --location $LOCATION

###create the HUB vnet with 3 subnets (FW, MGMT, and WAF)
$ az network vnet create \
  --name $HUB_VNET_NAME \
  --resource-group $RG \
  --location $LOCATION \
  --address-prefix $HUB_VNET_CIDR \
  --subnet-name $FW_SUBNET_NAME \
  --subnet-prefix $FW_SUBNET_PREFIX

$ az network vnet subnet create \
  --name $MGMT_SUBNET_NAME \
  --resource-group $RG \
  --vnet-name $HUB_VNET_NAME   \
  --address-prefix $MGMT_SUBNET_PREFIX


$ az network vnet subnet create \
  --name $WAF_SUBNET_NAME \
  --resource-group $RG \
  --vnet-name $HUB_VNET_NAME   \
  --address-prefix $WAF_SUBNET_PREFIX


###create AKS VNET with 2 subnets (AKS nodes and Ingress)
$ az network vnet create \
  --name $AKS_VNET_NAME \
  --resource-group $RG \
  --location $LOCATION \
  --address-prefix $AKS_VNET_CIDR \
  --subnet-name $AKS_NODES_SUBNET_NAME \
  --subnet-prefix $AKS_NODES_SUBNET_PREFIX


$ az network vnet subnet create \
  --name $AKS_INGRESS_SUBNET_NAME \
  --resource-group $RG \
  --vnet-name $AKS_VNET_NAME   \
  --address-prefix $AKS_INGRESS_SUBNET_PREFIX


######## Peer The Networks ########
$ az network vnet peering create \
 --name peer-hub-to-aks \
 --resource-group $RG \
 --remote-vnet $AKS_VNET_NAME \
 --vnet-name $HUB_VNET_NAME \
 --allow-gateway-transit \
 --allow-vnet-access


 $ az network vnet peering create \
 --name peer-aks-to-hub \
 --resource-group $RG \
 --remote-vnet $HUB_VNET_NAME \
 --vnet-name $AKS_VNET_NAME \
 --allow-vnet-access

 #Create and configure the firewall

 ### create the firewall
$ az network firewall create \
    --name $FW_NAME \
    --resource-group $RG \
    --location $LOCATION

###create public IP to be attached to the firewall
$ az network public-ip create \
    --name $FW_PUBLIC_IP_NAME \
    --resource-group $RG \
    --location $LOCATION \
    --allocation-method static \
    --sku standard

###get the IP and assign it to a variable
$ FW_PUBLIC_IP=$(az network public-ip show -g $RG -n $FW_PUBLIC_IP_NAME --query "ipAddress" -o tsv)

###assign the IP to the firewall
$ az network firewall ip-config create \
    --firewall-name $FW_NAME \
    --name $FW_CONFIG_NAME \
    --public-ip-address $FW_PUBLIC_IP_NAME \
    --resource-group $RG \
    --vnet-name $HUB_VNET_NAME

###get the firewall private IP so we can create the routes 
$ FW_PRIVATE_IP=$(az network firewall show -g $RG -n $FW_NAME --query "ipConfigurations[0].privateIpAddress" -o tsv)


###create a route table
$ az network route-table create \
    --name $FWROUTE_TABLE_NAME \
    --resource-group $RG \
    --location $LOCATION \
    --disable-bgp-route-propagation true

###create a route entry (Route all to Firewall)
$ az network route-table route create \
  --resource-group $RG \
  --name $FWROUTE_NAME \
  --route-table-name $FWROUTE_TABLE_NAME \
  --address-prefix 0.0.0.0/0 \
  --next-hop-type VirtualAppliance \
  --next-hop-ip-address $FW_PRIVATE_IP


### assign the route to the AKS Nodes Subnet
$ az network vnet subnet update \
    -n $AKS_NODES_SUBNET_NAME \
    -g $RG \
    --vnet-name $AKS_VNET_NAME \
    --address-prefixes $AKS_NODES_SUBNET_PREFIX \
    --route-table $FWROUTE_TABLE_NAME

### assign the route to the Mgmt Subnet
az network vnet subnet update \
    -n $MGMT_SUBNET_NAME \
    -g $RG \
    --vnet-name $HUB_VNET_NAME \
    --address-prefixes $MGMT_SUBNET_PREFIX \
    --route-table $FWROUTE_TABLE_NAME



####create the firewall rules

###create network rule, the rule is very permissive for demo reasons only, this can be restricted to the AKS API server IP/FQDN
$ az network firewall network-rule create \
-g $RG \
-f $FW_NAME \
--collection-name 'aksfwnr' \
-n 'netrules' \
--protocols 'Any' \
--source-addresses '*' \
--destination-addresses '*' \
--destination-ports 22 443 9000 1194 123 \
--action allow --priority 100

### create an application rule to allow the required FQDNs for AKS to function, this obvioulst will be overridden by the network rule, only when you allow 80 and 443 to a specific IP (API Server IP) the below will take affect
###AKS Egress Requirements https://docs.microsoft.com/en-us/azure/aks/limit-egress-traffic
###Azure Firewall rules logic https://docs.microsoft.com/en-us/azure/firewall/rule-processing
az network firewall application-rule create \
-g $RG \
-f $FW_NAME \
--collection-name 'AKS_Global_Required' \
--action allow \
--priority 100 \
-n 'required' \
--source-addresses '*' \
--protocols 'http=80' 'https=443' \
--target-fqdns \
        'aksrepos.azurecr.io' \
        '*blob.core.windows.net' \
        'mcr.microsoft.com' \
        '*cdn.mscr.io' \
        '*.data.mcr.microsoft.com' \
        'management.azure.com' \
        'login.microsoftonline.com' \
        'ntp.ubuntu.com' \
        'packages.microsoft.com' \
        'acs-mirror.azureedge.net' \
        'security.ubuntu.com' \
        'azure.archive.ubuntu.com' \
        'changelogs.ubuntu.com' 
