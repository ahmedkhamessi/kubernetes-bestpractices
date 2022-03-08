RG=aks-demos ## the resource group
LOCATION=westeurope ## the region 
AKS_VNET_NAME=aks-vnet ## the name of the VNET, we will be using CNI for this setup, Kubenet can be used too
AKS_CLUSTER_NAME=k8s-tenancy ## cluster name 
AKS_VNET_CIDR=192.168.32.0/19 ## the VNET CIDR 
AKS_NODES_SUBNET_NAME=aks-default-subnet ## The default subnet name
AKS_NODES_SUBNET_PREFIX=192.168.32.0/23 ## The default subnet IP space 
AKS_SPECIAL_APP_SUBNET_NAME=aks-special-app-subnet ## A subnet for special applications with strict isolation requirements 
AKS_SPECIAL_APP_SUBNET_PREFIX=192.168.35.0/24 ## special apps subnet IP space 
AAD_ADMIN_GROUP_ID=XXXXX-XXXX-XXXX-XXXX-XXXXX4ab04ab0 ## The AAD Group ID for the admins, follow instructions here https://docs.microsoft.com/en-gb/azure/active-directory/fundamentals/active-directory-groups-create-azure-portal
AAD_NAMESPACE_ADMIN_GROUP_ID=XXXXX-XXXX-XXXX-XXXX-XXXXX130b   ## The AAD Group ID for the Namespace admin
TENANT_ID=XXXXX-XXXX-XXXX-XXXX-XXXXXXXXXX ## Your AAD Tenant ID

#create the resource group
$ az group create --name $RG --location $LOCATION

#create AKS VNET with the default subnet
az network vnet create \
  --name $AKS_VNET_NAME \
  --resource-group $RG \
  --location $LOCATION \
  --address-prefix $AKS_VNET_CIDR \
  --subnet-name $AKS_NODES_SUBNET_NAME \
  --subnet-prefix $AKS_NODES_SUBNET_PREFIX

#create a subnet for the the applications with strict isolation requirements
az network vnet subnet create \
  --name $AKS_SPECIAL_APP_SUBNET_NAME \
  --resource-group $RG \
  --vnet-name $AKS_VNET_NAME   \
  --address-prefix $AKS_SPECIAL_APP_SUBNET_PREFIX


#store the IDs for both subnets 
AKS_VNET_SUBNET_ID=$(az network vnet subnet show --name $AKS_NODES_SUBNET_NAME -g $RG --vnet-name $AKS_VNET_NAME --query "id" -o tsv)
AKS_SPECIAL_APP_SUBNET_ID=$(az network vnet subnet show --name $AKS_SPECIAL_APP_SUBNET_NAME -g $RG --vnet-name $AKS_VNET_NAME --query "id" -o tsv)

# create the AKS cluster in multi zone, integrated with AAD using V2 experience. 
az aks create \
-g $RG \
-n $AKS_CLUSTER_NAME \
-l $LOCATION \
--zones 1 2 3 \
--nodepool-name defaultnp \
--enable-cluster-autoscaler \
--max-count 10 \
--min-count 2 \
--node-count 2 \
--node-vm-size Standard_B2s \
--network-plugin azure \
--generate-ssh-keys \
--service-cidr 10.0.0.0/16 \
--dns-service-ip 10.0.0.10 \
--docker-bridge-address 172.22.0.1/29 \
--vnet-subnet-id $AKS_VNET_SUBNET_ID \
--load-balancer-sku standard \
--enable-aad \
--aad-admin-group-object-ids $AAD_ADMIN_GROUP_ID \
--aad-tenant-id $TENANT_ID

# Add a node pool which will be dedicated for system resources (kube-system pods)
# CLI doesn't yet support adding nodepool taints at AKS provisioning time, this can be done using ARM templates.follow up on the issue here https://github.com/Azure/AKS/issues/1402
# Note the "--mode System" this is a new feature from AKS which will add affinity to system pods to always land in the (System Pool(s))
# Note the Taint (CriticalAddonsOnly=yes:NoExecute), AKS system pods come with a toleration for this taint by default 

az aks nodepool add \
--cluster-name $AKS_CLUSTER_NAME \
--resource-group $RG \
--zones 1 2 3 \
--name systempods \
--labels use=systempods \
--node-taint CriticalAddonsOnly=yes:NoExecute \
--mode System \
--enable-cluster-autoscaler \
--node-count 2 \
--max-count 10 \
--min-count 2 \
--node-vm-size Standard_B2s

# add another node pool which will be shared between tenants 
# this will instruct AKS that this pool is dedicated to pods which don't belong to Kube-system 

$ az aks nodepool add \
--cluster-name $AKS_CLUSTER_NAME \
--resource-group $RG \
--name tenantspool \
--zones 1 2 3 \
--labels use=tenants \
--mode User \
--enable-cluster-autoscaler \
--node-count 2 \
--max-count 10 \
--min-count 2 \
--node-vm-size Standard_B2s 

# add another node pool in a different subnet which will be dedicated for workload with strict isolation requirements 

$ az aks nodepool add \
--cluster-name $AKS_CLUSTER_NAME \
--resource-group $RG \
--name strictpool \
--zones 1 2 3 \
--labels use=regulated-workloads \
--node-taint workload=regulated:NoExecute \
--mode User \
--enable-cluster-autoscaler \
--node-count 1 \
--max-count 10 \
--min-count 1 \
--node-vm-size Standard_B2s \
--vnet-subnet-id $AKS_SPECIAL_APP_SUBNET_ID

# now delete the default node pool, this step is only require as CLI doesn't support adding taints during cluster provisioning time YET!
$ az aks nodepool delete \
--cluster-name $AKS_CLUSTER_NAME \
--resource-group $RG \
--name defaultnp

# list the pools 
$ az aks nodepool list \
--cluster-name $AKS_CLUSTER_NAME \
--resource-group $RG \
-o table


##create a namespace and add proper isolation controls on it
# create the "Tenant1" namesapce  
$ kubectl create namespace tenant1

# create the roles for the namespace admin 
$ cat <<EOF >tenant1_admin_rbac_role.yaml
kind: Role
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: tenant1-ns-admin-role
  namespace: tenant1
rules:
- apiGroups: ["", "extensions", "apps"]
  resources: ["*"]
  verbs: ["*"]
- apiGroups: ["batch"]
  resources:
  - jobs
  - cronjobs
  verbs: ["*"]
EOF

$ kubectl create -f tenant1_admin_rbac_role.yaml 

#change the group ID of the tenant1 admin
$ cat <<EOF >tenant1_admin_rolebinding.yaml
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: tenant1-ns-admin-rolebinding
  namespace: tenant1
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: tenant1-ns-admin-role
subjects:
- kind: Group
  namespace: tenant1
  name: #PLCAEHOLDER FOR THE TENANT1 NAMESPACE ADMIN GROUP ID
EOF

$ kubectl create -f tenant1_admin_rolebinding.yaml

# repeat the same for the namespace developer with the desired permissions 



# apply resource quotas to the namespace 
$ cat <<EOF >tenant1_namespace_resource_quotas.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant1-compute-resources-limits
spec:
  hard:
    requests.cpu: "3"
    requests.memory: 3000M
    limits.cpu: "3"
    limits.memory: 3000M
EOF

$ kubectl apply -f tenant1_namespace_resource_quotas.yaml --namespace=tenant1

#apply pod limit range, so pods which don't claim resource quotas are capped by default
$ cat <<EOF >tenant1_namespace_limit_range.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: tenant1-namespace-limit-range
spec:
  limits:
  - default:
      memory: 150M
      cpu: 0.1
    defaultRequest:
      memory: 150M
      cpu: 0.1
    type: Container
EOF

$ kubectl apply -f tenant1_namespace_limit_range.yaml --namespace=tenant1

# create an ingress controller in this namespace (the below example is using HELM3)
$ helm install tenant1-ingress \
stable/nginx-ingress \
--namespace=tenant1 \
--set rbac.create=true \
--set controller.scope.namespace=tenant1 \
--set controller.service.externalTrafficPolicy=Local \
--set controller.service.type=LoadBalancer

#create a default network policy for this namespace (we will allow ingress 80,443 and egress on 53 only)
$ cat <<EOF >tenant1_network_policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: tenant1-network-policy
  namespace: tenant1
spec:
  podSelector:
    matchLabels: {}
  policyTypes:
  - Egress
  - Ingress
  egress:
    - ports:
      - port: 53
        protocol: UDP
      - port: 53
        protocol: TCP
      to: []
  ingress:
    - ports:
      - port: 80
        protocol: TCP
      - port: 443
        protocol: TCP
      from: []
EOF

$ kubectl create -f tenant1_network_policy.yaml


##Test
kubectl create deployment nginx --image=nginx --namespace=tenant1
