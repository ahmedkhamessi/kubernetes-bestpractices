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

###create network rule, In production should be restricted to the AKS API server IP/FQDN
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

###Deploy Azure Application Gateway

###create a public IP for the Application Gateway which will act as a WAF
$ az network public-ip create \
  --resource-group $RG \
  --name $APPGW_PIP_NAME \
  --allocation-method Static \
  --sku Standard

### create the Application Gateway, we will create an empty gateway and we will update the backend pool later when we create our first application
### I'm creating a plain HTTP WAF for demo purposes only, in your case this would be TLS

$ az network application-gateway create \
  --name $APPGW_NAME \
  --location $LOCATION \
  --resource-group $RG \
  --vnet-name $HUB_VNET_NAME \
  --subnet $WAF_SUBNET_NAME \
  --capacity 1 \
  --sku WAF_v2 \
  --http-settings-cookie-based-affinity Disabled \
  --frontend-port 80 \
  --http-settings-port 80 \
  --http-settings-protocol Http \
  --public-ip-address $APPGW_PIP_NAME

### update the WAF rules
az network application-gateway waf-config set \
  --enabled true \
  --gateway-name $APPGW_NAME \
  --resource-group $RG \
  --firewall-mode Detection \
  --rule-set-version 3.0

#Create the AKS cluster

### first we create the SP that we will use and assign permissions on the VNET
$ az ad sp create-for-rbac -n "akhamessiakssp" --skip-assignment

##Output
APPID="f5046eec-3559-4689-8708-0ca91f2b5a19"
PASSWORD="0mhKkJRNAzHBQE4-OQCGG9-QYeVD.JCD1w"

### get the vnet ID
VNETID=$(az network vnet show -g $RG --name $AKS_VNET_NAME --query id -o tsv)

# Assign SP Permission to VNET
$ az role assignment create --assignee $APPID --scope $VNETID --role Contributor

# View Role Assignment
$ az role assignment list --assignee $APPID --all -o table

## get the subnet ID of AKS and your Current IP so you can access the cluster 
$ CURRENT_IP=$(dig @resolver1.opendns.com ANY myip.opendns.com +short)
$ AKS_VNET_SUBNET_ID=$(az network vnet subnet show --name $AKS_NODES_SUBNET_NAME -g $RG --vnet-name $AKS_VNET_NAME --query "id" -o tsv)


### create the cluster
az aks create \
-g $RG \
-n $AKS_CLUSTER_NAME \
-l $LOCATION \
--node-count 2 \
--node-vm-size Standard_B2s \
--network-plugin azure \
--generate-ssh-keys \
--service-cidr 10.0.0.0/16 \
--dns-service-ip 10.0.0.10 \
--docker-bridge-address 172.22.0.1/29 \
--vnet-subnet-id $AKS_VNET_SUBNET_ID \
--load-balancer-sku standard \
--outbound-type userDefinedRouting \
--api-server-authorized-ip-ranges $FW_PUBLIC_IP/32,$CURRENT_IP/32 \
--service-principal $APPID \
--client-secret $PASSWORD 

### get the credentials 
$ az aks get-credentials -n $AKS_CLUSTER_NAME -g $RG

#[Optional]
###Create the jump box in the management subnet

#####Create the Jump box and create
az vm create \
-n jumpbox \
-g $RG \
--vnet-name $HUB_VNET_NAME \
--subnet $MGMT_SUBNET_NAME \
--image UbuntuLTS \
--location $LOCATION \
--size Standard_B1s \
--public-ip-address "" \
--admin-username adminusername \
--ssh-key-values ~/.ssh/id_rsa.pub


### get the IP of your jumpbox
$ JUMPBOX_IP=$(az vm show --show-details  --name jumpbox -g $RG --query "privateIps" -o tsv)


###create a DNAT rule in the firewall to access the jump box, the role is open for sources but you can lock it down obviously

$ az network firewall nat-rule create \
--collection-name jumpbox \
--destination-addresses $FW_PUBLIC_IP \
--destination-ports 22 \
--firewall-name $FW_NAME \
--name inboundrule \
--protocols Any \
--resource-group $RG \
--source-addresses '*' \
--translated-port 22 \
--action Dnat \
--priority 110 \
--translated-address $JUMPBOX_IP

## SSH to the Jump Box
$ ssh adminusername@$FW_PUBLIC_IP -i ~/.ssh/id_rsa


#install the tools in
#install kubectl
sudo apt-get update && sudo apt-get install -y apt-transport-https
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee -a /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubectl


#install azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

#login to your account
az login 

#get the AKS credintials 
az aks get-credentials -n $AKS_CLUSTER_NAME -g $RG

#test 
kubectl get nodes


#Create a test application
cat << EOF | kubectl apply -f - 
apiVersion: v1
kind: Service
metadata:
  name: internal-app
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "aks-ingress-subnet"
spec:
  type: LoadBalancer
  ports:
  - port: 80
  selector:
    app: internal-app
EOF

EXTERNAL_ILB_IP=192.168.34.4

cat << EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: azure-vote-back
spec:
  replicas: 1
  selector:
    matchLabels:
      app: azure-vote-back
  template:
    metadata:
      labels:
        app: azure-vote-back
    spec:
      nodeSelector:
        "beta.kubernetes.io/os": linux
      containers:
      - name: azure-vote-back
        image: redis
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 250m
            memory: 256Mi
        ports:
        - containerPort: 6379
          name: redis
---
apiVersion: v1
kind: Service
metadata:
  name: azure-vote-back
spec:
  ports:
  - port: 6379
  selector:
    app: azure-vote-back
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: internal-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: internal-app
  template:
    metadata:
      labels:
        app: internal-app
    spec:
      nodeSelector:
        "beta.kubernetes.io/os": linux
      containers:
      - name: azure-vote-front
        image: microsoft/azure-vote-front:v1
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 250m
            memory: 256Mi
        ports:
        - containerPort: 80
        env:
        - name: REDIS
          value: "azure-vote-back"
EOF

###Configure APP GW and test
### now we need to update the backend pool of the APP GW with our service EXTERNAL IP
$ az network application-gateway address-pool update \
 --servers $EXTERNAL_ILB_IP \
 --gateway-name $APPGW_NAME \
 -g $RG \
 -n appGatewayBackendPool

##Test the setup
### get the Public IP of the APP GW
$ WAF_PUBLIC_IP=$(az network public-ip show --resource-group $RG --name $APPGW_PIP_NAME --query [ipAddress] --output tsv)

### test using Curl 
$ curl $WAF_PUBLIC_IP