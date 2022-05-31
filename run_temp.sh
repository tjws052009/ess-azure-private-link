#!/bin/bash
# Must use values from personal ESS account
# API Key for authentication to ESS API
# Deployment ID of the targer cluster
DEPLOYMENT_ID=<insert ESS deployment ID>
EC_API_KEY=<insert Elastic Cloud API Key>

NEWRG=apltest1-rg
SUBNETIP=172.20.1.0/24
DNSZONE=privatelink.japaneast.azure.elastic-cloud.com
PRIVATEENDPOINT_NAME=apltest1
VNET_NAME=apltest1
LOCATION=japaneast
ESS_LOCATION=azure-japaneast

# You need to use the same location
az group create -n $NEWRG -l $LOCATION

# This creates 3 Azure resources using a ARM template
#   - VNet
#   - Private DNS
#   - Private Endpoint (also auto creates a NIC)
az deployment group create --resource-group $NEWRG --template-file template.json --parameters vnet_subnet=$SUBNETIP privateDnsZones_pl_azelastic_com_name=$DNSZONE virtualNetworks_vnet_name=$VNET_NAME privateEndpoints_pe_name=$PRIVATEENDPOINT_NAME location=$LOCATION


# Retrieve private ip of the Private Endpoint. This will be the internal private IP that is used to connect to ESS via private link
NIC_IP=$(az network nic list -g $NEWRG --query "[0].ipConfigurations[0].privateIpAddress" -o tsv)

# Updates the private dns with an A record, * that resolves to the private IP
az network private-dns record-set a add-record -g $NEWRG -z $DNSZONE --ipv4-address $NIC_IP --record-set-name "*"

# Retreive necessary values to setup Private Link in the ESS portal
GUID=$(az resource show --ids `az network private-endpoint show -g $NEWRG -n $PRIVATEENDPOINT_NAME --query "id" -o tsv` --query "properties.resourceGuid" -o tsv)

RESP=$(curl -s -XPOST https://api.elastic-cloud.com/api/v1/deployments/traffic-filter/rulesets \
-H "Authorization: ApiKey $EC_API_KEY" \
-H 'Content-Type: application/json' \
-d "
{
  \"description\" : \"string\",
  \"include_by_default\" : false,
  \"name\" : \"azpl\",
  \"region\" : \"$ESS_LOCATION\",
  \"description\" : \"test private link\",
  \"type\" : \"azure_private_endpoint\",
  \"rules\" : [
    {
      \"azure_endpoint_guid\" : \"$GUID\",
      \"azure_endpoint_name\" : \"$PRIVATEENDPOINT_NAME\"
    }
  ]
}
")

RULESET_ID=$(echo $RESP | jq ".id" -r)

curl -XPOST https://api.elastic-cloud.com/api/v1/deployments/traffic-filter/rulesets/$RULESET_ID/associations \
-H "Authorization: ApiKey $EC_API_KEY" \
-H 'Content-Type: application/json' \
-d "
{
   \"entity_type\" : \"deployment\",
   \"id\" : \"$DEPLOYMENT_ID\"
}
"

RESP=$(curl -XGET https://api.elastic-cloud.com/api/v1/deployments/$DEPLOYMENT_ID -H "Authorization: ApiKey $EC_API_KEY")
ES_ID=$(echo $RESP | jq ".resources.elasticsearch[].id" -r)

echo "========================================="
echo "These parameters are use for traffic filter settings"
echo ""
echo "Resource name: $PRIVATEENDPOINT_NAME"
echo "Resource ID: $GUID"
echo ""
echo "Below is the internal URL to access via private endpoint"
echo "https://$ES_ID.$DNSZONE:9243"
echo "========================================="

