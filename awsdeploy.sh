#!/bin/bash

awsRegion="us-east-1"
awsProfile="default"
nameSpace="demo" #needs to match nginx/site.conf
deployTag=$(date +"%s")

echo "
    _  _____ ____ 
   / \|_   _/ ___|
  / _ \ | || |    
 / ___ \| || |___ 
/_/   \_\_| \____|
NGINX & PHP AWS Deploy Script

To check the logs run:
    tail ./deploy.log

    Deployment tag is $deployTag
"

######################################
##  Configuring VPC with 2 private  ##
##  subnets and 2 public subnets    ##
##  within AZ-a and AZ-b            ##
######################################
echo "Configuring VPC with 2 private and 2 public subnets"
vpcId=$(aws ec2 create-vpc --cidr-block "10.0.0.0/16" --region $awsRegion --profile $awsProfile | jq -r .Vpc.VpcId)
aws ec2 modify-vpc-attribute --vpc-id $vpcId --enable-dns-hostnames "{\"Value\":true}" --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
igwId=$(aws ec2 create-internet-gateway --region $awsRegion --profile $awsProfile | jq -r .InternetGateway.InternetGatewayId)
aws ec2 attach-internet-gateway --internet-gateway-id $igwId --vpc-id $vpcId --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
# Create a private subnet on AZ-a
subnetId1=$(aws ec2 create-subnet --cidr-block "10.0.0.0/24" --vpc-id $vpcId --availability-zone $awsRegion'a' --region $awsRegion --profile $awsProfile | jq -r .Subnet.SubnetId)
# Create a private subnet on AZ-b
subnetId2=$(aws ec2 create-subnet --cidr-block "10.0.1.0/24" --vpc-id $vpcId --availability-zone $awsRegion'b' --region $awsRegion --profile $awsProfile | jq -r .Subnet.SubnetId)
# Create a public subnet on AZ-a
subnetId3=$(aws ec2 create-subnet --cidr-block "10.0.10.0/24" --vpc-id $vpcId --availability-zone $awsRegion'a' --region $awsRegion --profile $awsProfile | jq -r .Subnet.SubnetId)
# Create public subnet on AZ-b
subnetId4=$(aws ec2 create-subnet --cidr-block "10.0.11.0/24" --vpc-id $vpcId --availability-zone $awsRegion'b' --region $awsRegion --profile $awsProfile | jq -r .Subnet.SubnetId)
# Create route table for public subnet
publicRtbId=$(aws ec2 create-route-table --vpc-id $vpcId --region $awsRegion --profile $awsProfile | jq -r .RouteTable.RouteTableId)
# Add route 0.0.0.0/0 to IGW for public route table
aws ec2 create-route --gateway-id $igwId --route-table-id $publicRtbId --destination-cidr-block 0.0.0.0/0 --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
# Associate public subnets with public route table
aws ec2 associate-route-table --route-table-id $publicRtbId --subnet-id $subnetId3 --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
aws ec2 associate-route-table --route-table-id $publicRtbId --subnet-id $subnetId4 --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
# Create elastic IP for NAT gateway
eipId=$(aws ec2 allocate-address --domain vpc --region $awsRegion --profile $awsProfile | jq -r .AllocationId)
# Create a NAT gateway for private subnets and place it on a public subnet
natId=$(aws ec2 create-nat-gateway --allocation-id $eipId --subnet-id $subnetId3 --region $awsRegion --profile $awsProfile | jq -r .NatGateway.NatGatewayId)
# Create route table for private subnets
privateRtbId=$(aws ec2 create-route-table --vpc-id $vpcId --region $awsRegion --profile $awsProfile | jq -r .RouteTable.RouteTableId)
# Add route 0.0.0.0/0 to NAT for private subnets
aws ec2 create-route --gateway-id $natId --route-table-id $privateRtbId --destination-cidr-block 0.0.0.0/0 --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
# Associate private subnets with private route table
aws ec2 associate-route-table --route-table-id $privateRtbId --subnet-id $subnetId1 --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
aws ec2 associate-route-table --route-table-id $privateRtbId --subnet-id $subnetId2 --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
echo "      Reource IDs: $vpcId, $igwId, $natId" >> ./deploy.log
echo "      Private Subnets: $subnetId1, $subnetId2" >> ./deploy.log
echo "      Public Subnets: $subnetId3, $subnetId4" >> ./deploy.log


######################################
##  Configuring Security Groups &   ##
##  IAM Roles                       ##
######################################
echo "Configuring security groups and IAM roles"
taskExecutionRoleARN=$(aws iam create-role --role-name $deployTag-ecsTaskExecution --assume-role-policy-document '{"Version": "2008-10-17","Statement": [{"Sid": "","Effect": "Allow","Principal": {"Service": "ecs-tasks.amazonaws.com"},"Action": "sts:AssumeRole"}]}' --region $awsRegion --profile $awsProfile | jq -r .Role.Arn)
# Attach AWS managed AmazonECSTaskExecutionRolePolicy to above IAM role
aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy --role-name $deployTag-ecsTaskExecution --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
# Create Security Group which will be shared among containers
securityGroupId=$(aws ec2 create-security-group --description "Security Group for Fargate Task" --group-name "$deployTag-fargatetasks" --vpc-id $vpcId --region $awsRegion --profile $awsProfile | jq -r .GroupId)
# Add security group rules
aws ec2 authorize-security-group-ingress --group-id $securityGroupId --protocol "all" --port "-1" --source-group $securityGroupId --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
# Create security group for ALB
ALBsecurityGroupId=$(aws ec2 create-security-group --description "Security Group for Fargate ALB" --group-name "$deployTag-albsg" --vpc-id $vpcId --region $awsRegion --profile $awsProfile | jq -r .GroupId)
# Allow all incoming connections on tcp 80 for ALB
aws ec2 authorize-security-group-ingress --group-id $ALBsecurityGroupId --protocol "tcp" --port "80" --cidr 0.0.0.0/0 --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
# Allowing tcp 80 from ALB to Fargate tasks security group
aws ec2 authorize-security-group-ingress --group-id $securityGroupId --protocol "tcp" --port "80" --source-group $ALBsecurityGroupId --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
echo "      ALB sg: $ALBsecurityGroupId" >> ./deploy.log
echo "      Task execution IAM role: $taskExecutionRoleARN" >> ./deploy.log
echo "      Task security group Id: $securityGroupId" >> ./deploy.log

######################################
##  Creating Application Load       ##
##  Balancer on public subnets      ##
######################################
echo "Creating Application Load Balancer on public subnets"
loadBalancerArn=$(aws elbv2 create-load-balancer --name "$deployTag-fargatealb" --subnets $subnetId3 $subnetId4 --security-groups $ALBsecurityGroupId --scheme "internet-facing" --type "application" --ip-address-type "ipv4" --region $awsRegion --profile $awsProfile | jq -r .LoadBalancers[0].LoadBalancerArn)
echo "      $loadBalancerArn" >> ./deploy.log
# Create target group for ALB
nginxTargetGroupARN=$(aws elbv2 create-target-group --name "$deployTag-nginx-albtg" --protocol "HTTP" --port 80 --vpc-id "$vpcId" --target-type "ip" --region $awsRegion --profile $awsProfile | jq -r .TargetGroups[0].TargetGroupArn)
echo "      $nginxTargetGroupARN" >> ./deploy.log
# Associate target group with load balancer
aws elbv2 create-listener --load-balancer-arn $loadBalancerArn --protocol "HTTP" --port "80" --default-actions Type=forward,TargetGroupArn=$nginxTargetGroupARN --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

######################################
##  Configuring CloudWatch          ##
##  log groups                      ##
######################################
echo "Creating CloudWatch log groups"
aws logs create-log-group --log-group-name /ecs/$deployTag-php-$nameSpace --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
aws logs create-log-group --log-group-name /ecs/$deployTag-nginx-$nameSpace --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

######################################
##  Configuring ECS & Fargate       ##
######################################
# Create ECS Repository and tag docker images with ecsRepositoryUri
echo "Creating ECS Repository $deployTag-fargaterepo"
ecsRepositoryUri=$(aws ecr create-repository --repository-name $deployTag-fargaterepo --region $awsRegion --profile $awsProfile | jq -r .repository.repositoryUri)
echo "      $ecsRepositoryUri" >> ./deploy.log
echo "Building and tagging Docker images..."
docker build -t $ecsRepositoryUri:nginx.$nameSpace ./nginx >>./deploy.log 2>&1
docker build -t $ecsRepositoryUri:php.$nameSpace ./php >>./deploy.log 2>&1
# Obtain aws credentials for docker
echo "Obtaining credentials for docker push"
aws ecr get-login --no-include-email --region $awsRegion --profile $awsProfile | awk '{printf $6}' | docker login -u AWS $ecsRepositoryUri --password-stdin
# Push docker images to AWS Repo
echo "Pushing Docker images..."
docker push $ecsRepositoryUri:nginx.$nameSpace >>./deploy.log 2>&1
docker push $ecsRepositoryUri:php.$nameSpace >>./deploy.log 2>&1
# Register task definitions
echo "Registering ECS Task Definitions php & nginx"
aws ecs register-task-definition --container-definitions '[{"name": "php-'$nameSpace'","image": "'$ecsRepositoryUri':php.'$nameSpace'","essential": true,"logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group": "/ecs/'$deployTag'-php-'$nameSpace'","awslogs-region": "'$awsRegion'","awslogs-stream-prefix": "ecs"}}}]' --family "php-$nameSpace" --requires-compatibilities "FARGATE"  --network-mode "awsvpc" --cpu "256" --memory "512" --task-role "$taskExecutionRoleARN" --execution-role-arn "$taskExecutionRoleARN" --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
aws ecs register-task-definition --container-definitions '[{"name": "nginx-'$nameSpace'","image": "'$ecsRepositoryUri':nginx.'$nameSpace'","essential": true,"logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group": "/ecs/'$deployTag'-nginx-'$nameSpace'","awslogs-region": "'$awsRegion'","awslogs-stream-prefix": "ecs"}}, "portMappings": [{"hostPort": 80,"protocol": "tcp","containerPort": 80}]}]' --family "nginx-$nameSpace" --requires-compatibilities "FARGATE"  --network-mode "awsvpc" --cpu "256" --memory "512" --task-role "$taskExecutionRoleARN" --execution-role-arn "$taskExecutionRoleARN" --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
# Create Service Discovery name space required for Fargate PHP service
echo "Creating Service Discovery namespace: $nameSpace (this will take a while)"
nameSpaceOperationId=$(aws servicediscovery create-private-dns-namespace --name $nameSpace --vpc $vpcId --region $awsRegion --profile $awsProfile | jq -r .OperationId)
nameSpaceOperationStatus=$(aws servicediscovery get-operation --operation-id $nameSpaceOperationId --region $awsRegion --profile $awsProfile | jq -r .Operation.Status)
nameSpaceId=$(aws servicediscovery get-operation --operation-id $nameSpaceOperationId --region $awsRegion --profile $awsProfile | jq -r .Operation.Targets.NAMESPACE)
while [ $nameSpaceOperationStatus != "SUCCESS" ]; do
    echo "$nameSpaceOperationStatus $nameSpaceOperationId"
    sleep 30
    nameSpaceOperationStatus=$(aws servicediscovery get-operation --operation-id $nameSpaceOperationId --region $awsRegion --profile $awsProfile | jq -r .Operation.Status)
done
echo "Namespace status is $nameSpaceOperationStatus and namespace Id is $nameSpaceId" >> ./deploy.log
# Create Service Discovery service (servicename.namespace)
echo "Creating Servicediscovery service named: php"
PHPregistryArn=$(aws servicediscovery create-service --name "php" --dns-config 'NamespaceId="'$nameSpaceId'",DnsRecords=[{Type="A",TTL="300"}]' --health-check-custom-config FailureThreshold=1 --region $awsRegion --profile $awsProfile | jq -r .Service.Arn)
# Create Fargate Cluster
echo "Creating Fargate cluster"
clusterArn=$(aws ecs create-cluster --cluster-name "$deployTag-fargatecluster" --region $awsRegion --profile $awsProfile | jq -r .cluster.clusterArn)
echo "      $clusterArn" >> ./deploy.log
# Create Fargate Cluster PHP Service with Service Discovery
echo "Creating Fargate cluster Service named: php"
aws ecs create-service --cluster $clusterArn --service-name "php" --task-definition "php-$nameSpace" --desired-count 1 --service-registries '[{"registryArn":"'$PHPregistryArn'"}]' --launch-type "FARGATE" --network-configuration "awsvpcConfiguration={subnets=[$subnetId1,$subnetId2],securityGroups=[$securityGroupId],assignPublicIp=DISABLED}" --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
echo "Creating fargate cluster Service named: nginx"
aws ecs create-service --cluster $clusterArn --service-name "nginx" --task-definition "nginx-$nameSpace" --desired-count 1 --load-balancers "targetGroupArn=$nginxTargetGroupARN,containerName=nginx-$nameSpace,containerPort=80" --launch-type "FARGATE" --network-configuration "awsvpcConfiguration={subnets=[$subnetId1,$subnetId2],securityGroups=[$securityGroupId],assignPublicIp=DISABLED}" --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
echo "Retrieving URL for Aplication Load Balancer"
loadBalancerDns=$(aws elbv2 describe-load-balancers --load-balancer-arns $loadBalancerArn  --region $awsRegion --profile $awsProfile | jq -r .LoadBalancers[0].DNSName)
echo "

    http://$loadBalancerDns
    
"