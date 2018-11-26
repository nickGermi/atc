#!/bin/bash

#variables
awsRegion="us-east-1"
awsProfile="default"
ecsRepositoryName="demo"
nameSpace="demo"
iamRolePrefix="demo"
fargateClusterName="demo"

echo "
    _  _____ ____ 
   / \|_   _/ ___|
  / _ \ | || |    
 / ___ \| || |___ 
/_/   \_\_| \____|
NGINX & PHP AWS Deploy Script

To check the logs run:
    tail ./deploy.log

"
# Create ECS Repository and tag docker images with ecsRepositoryUri
echo "1/24  Creating ECS Repository..."
ecsRepositoryUri=$(aws ecr create-repository --repository-name $ecsRepositoryName --region $awsRegion --profile $awsProfile | jq -r .repository.repositoryUri)
echo "     ECS Repository URI is $ecsRepositoryUri"
echo "2/24  Building and tagging Docker images..."
docker build -t $ecsRepositoryUri:nginx.example ./nginx >>./deploy.log 2>&1
docker build -t $ecsRepositoryUri:php.example ./php >>./deploy.log 2>&1

# Obtain aws credentials and push docker images
echo "3/24  Getting AWS Credentials to push docker images"
$(aws ecr get-login --no-include-email --region $awsRegion --profile $awsProfile)
echo "4/24  Pushing Docker images..."
docker push $ecsRepositoryUri:nginx.example >>./deploy.log 2>&1
docker push $ecsRepositoryUri:php.example >>./deploy.log 2>&1

# Create required IAM Roles
echo "5/24  Creating IAM Role $iamRolePrefix-ecsTaskExecution"
taskExecutionRoleARN=$(aws iam create-role --role-name $iamRolePrefix-ecsTaskExecution --assume-role-policy-document file://./taskExecutionRolePolicy.json --region $awsRegion --profile $awsProfile | jq -r .Role.Arn)
echo "     Role ARN is $taskExecutionRoleARN"

# Attach AWS managed AmazonECSTaskExecutionRolePolicy to above IAM role
echo "6/24  Attaching AmazonECSTaskExecutionRolePolicy to $iamRolePrefix-ecsTaskExecution"
aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy --role-name $iamRolePrefix-ecsTaskExecution --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

# Register task definitions
echo "7/24  Registering ECS Task Definitions"
aws ecs register-task-definition --container-definitions '[{"name": "php-example","image": "'$ecsRepositoryUri':php.example","essential": true}]' --family "php-example" --requires-compatibilities "FARGATE"  --network-mode "awsvpc" --cpu "256" --memory "512" --task-role "$taskExecutionRoleARN" --execution-role-arn "$taskExecutionRoleARN" --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
aws ecs register-task-definition --container-definitions '[{"name": "nginx-example","image": "'$ecsRepositoryUri':nginx.example","essential": true, "portMappings": [{"hostPort": 80,"protocol": "tcp","containerPort": 80}]}]' --family "nginx-example" --requires-compatibilities "FARGATE"  --network-mode "awsvpc" --cpu "256" --memory "512" --task-role "$taskExecutionRoleARN" --execution-role-arn "$taskExecutionRoleARN" --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

# Create VPC for Fargate cluster
echo "8/24  Creating VPC for Fargate cluster"
vpcId=$(aws ec2 create-vpc --cidr-block "10.0.0.0/16" --region $awsRegion --profile $awsProfile | jq -r .Vpc.VpcId)
echo "     VPC Id is $vpcId"

#create internetgateway
echo "9/24  Creating Internet Gateway"
igwId=$(aws ec2 create-internet-gateway --region $awsRegion --profile $awsProfile | jq -r .InternetGateway.InternetGatewayId)
echo "     Internet Gateway Id is $igwId"
#associate internetgateway with vpc
echo "10/24 Assosiating IGW with VPC"
aws ec2 attach-internet-gateway --internet-gateway-id $igwId --vpc-id $vpcId --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
# Get default route table id
echo "11/24 Getting default Route Table Id"
rtbId=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpcId" --region $awsRegion --profile $awsProfile | jq -r .RouteTables[0].RouteTableId)
#add routetable 0.0.0.0/0 > igw
echo "12/24 Adding default route to Internet"
aws ec2 create-route --gateway-id $igwId --route-table-id $rtbId --destination-cidr-block 0.0.0.0/0 --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

# Create 2 Subnets for Fargate cluster
echo '13/24 Creating subnets in AZ '$awsRegion'a and '$awsRegion'b'
subnetId1=$(aws ec2 create-subnet --cidr-block "10.0.0.0/24" --vpc-id $vpcId --availability-zone $awsRegion'a' --region $awsRegion --profile $awsProfile | jq -r .Subnet.SubnetId)
subnetId2=$(aws ec2 create-subnet --cidr-block "10.0.1.0/24" --vpc-id $vpcId --availability-zone $awsRegion'b' --region $awsRegion --profile $awsProfile | jq -r .Subnet.SubnetId)
echo "     Subnet Ids are $subnetId1 & $subnetId2"

# Create Security Group which will be shared among containers
echo "14/24 Creating Security Group"
securityGroupId=$(aws ec2 create-security-group --description "example" --group-name "example" --vpc-id $vpcId --region $awsRegion --profile $awsProfile | jq -r .GroupId)
echo "     Security Group ID is $securityGroupId"

# Add security group rules
echo "15/24 Adding security group rule allowing all traffic to and from security group itself"
aws ec2 authorize-security-group-ingress --group-id $securityGroupId --protocol "all" --port "-1" --source-group $securityGroupId --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

#create additional security groups for load balancer allowing port 80 for public

# Create Service Discovery name space required for Fargate PHP service
echo "16/24 Creating Service Discovery namespace: $nameSpace (this will take a while)"
nameSpaceOperationId=$(aws servicediscovery create-private-dns-namespace --name $nameSpace --vpc $vpcId --region $awsRegion --profile $awsProfile | jq -r .OperationId)
nameSpaceOperationStatus=$(aws servicediscovery get-operation --operation-id $nameSpaceOperationId --region $awsRegion --profile $awsProfile | jq -r .Operation.Status)
nameSpaceId=$(aws servicediscovery get-operation --operation-id $nameSpaceOperationId --region $awsRegion --profile $awsProfile | jq -r .Operation.Targets.NAMESPACE)

while [ $nameSpaceOperationStatus != "SUCCESS" ]; do
    echo "     - $nameSpaceOperationStatus $nameSpaceOperationId"
    sleep 10
    nameSpaceOperationStatus=$(aws servicediscovery get-operation --operation-id $nameSpaceOperationId --region $awsRegion --profile $awsProfile | jq -r .Operation.Status)
done
echo "     Namespace status is $nameSpaceOperationStatus and namespace Id is $nameSpaceId"

# Create Service Discovery service (servicename.namespace)
echo "17/24 Creating Service Discovery service named: php"
PHPregistryArn=$(aws servicediscovery create-service --name "php" --dns-config 'NamespaceId="'$nameSpaceId'",DnsRecords=[{Type="A",TTL="300"}]' --health-check-custom-config FailureThreshold=1 --region $awsRegion --profile $awsProfile | jq -r .Service.Arn)

# Create Fargate Cluster
echo "18/24 Creating Fargate cluster"
clusterArn=$(aws ecs create-cluster --cluster-name "$fargateClusterName" --region $awsRegion --profile $awsProfile | jq -r .cluster.clusterArn)
echo "     Cluster ARN is $clusterArn"

# Create Fargate Cluster PHP Service with Service Discovery
echo "19/24 Creating Fargate cluster Service named: php-example"
aws ecs create-service --cluster $clusterArn --service-name "php-example" --task-definition "php-example" --desired-count 1 --service-registries '[{"registryArn":"'$PHPregistryArn'"}]' --launch-type "FARGATE" --network-configuration "awsvpcConfiguration={subnets=[$subnetId1,$subnetId2],securityGroups=[$securityGroupId],assignPublicIp=ENABLED}" --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

# Create Application Load Balancer for NGINX container
echo "20/24 Creating Application Load Balancer"
loadBalancerArn=$(aws elbv2 create-load-balancer --name "fargate-alb" --subnets $subnetId1 $subnetId2 --security-groups $securityGroupId --scheme "internet-facing" --type "application" --ip-address-type "ipv4" --region $awsRegion --profile $awsProfile | jq -r .LoadBalancers[0].LoadBalancerArn)
echo "     Load balancer ARN is $loadBalancerArn"
echo "21/24 Creating Target Group for Application Load Balancer"
nginxTargetGroupARN=$(aws elbv2 create-target-group --name "nginx-example" --protocol "HTTP" --port 80 --vpc-id "$vpcId" --target-type "ip" --region $awsRegion --profile $awsProfile | jq -r .TargetGroups[0].TargetGroupArn)

# Associate target group with load balancer
echo "22/24 Associating Target Group with Application Load Balancer"
aws elbv2 create-listener --load-balancer-arn $loadBalancerArn --protocol "HTTP" --port "80" --default-actions Type=forward,TargetGroupArn=$nginxTargetGroupARN --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

# Create Fargate Cluster NGINX Service with Application Load Balancer
echo "23/24 Creating fargate cluster Service named: nginx-example"
aws ecs create-service --cluster $clusterArn --service-name "nginx-example" --task-definition "nginx-example" --desired-count 1 --load-balancers "targetGroupArn=$nginxTargetGroupARN,containerName=nginx-example,containerPort=80" --launch-type "FARGATE" --network-configuration "awsvpcConfiguration={subnets=[$subnetId1,$subnetId2],securityGroups=[$securityGroupId],assignPublicIp=ENABLED}" --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

echo "24/24 Getting URL for Aplication Load Balancer"
loadBalancerDns=$(aws elbv2 describe-load-balancers --load-balancer-arns $loadBalancerArn  --region $awsRegion --profile $awsProfile | jq -r .LoadBalancers[0].DNSName)
echo "

    http://$loadBalancerDns
    
"