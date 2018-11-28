#!/bin/bash

awsRegion="ap-southeast-2"
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

# Create ECS Repository and tag docker images with ecsRepositoryUri
echo "1/27  Creating ECS Repository $deployTag-fargaterepo"
ecsRepositoryUri=$(aws ecr create-repository --repository-name $deployTag-fargaterepo --region $awsRegion --profile $awsProfile | jq -r .repository.repositoryUri)
echo "      $ecsRepositoryUri"
echo "2/27  Building and tagging Docker images..."
docker build -t $ecsRepositoryUri:nginx.$nameSpace ./nginx >>./deploy.log 2>&1
docker build -t $ecsRepositoryUri:php.$nameSpace ./php >>./deploy.log 2>&1

# Obtain aws credentials for docker
echo "3/27  Obtaining credentials for docker push"
aws ecr get-login --no-include-email --region $awsRegion --profile $awsProfile | awk '{printf $6}' | docker login -u AWS $ecsRepositoryUri --password-stdin

# Push docker images to AWS Repo
echo "4/27  Pushing Docker images..."
docker push $ecsRepositoryUri:nginx.$nameSpace >>./deploy.log 2>&1
docker push $ecsRepositoryUri:php.$nameSpace >>./deploy.log 2>&1

# Create required IAM Roles
echo "5/27  Creating IAM Role $deployTag-ecsTaskExecution"
taskExecutionRoleARN=$(aws iam create-role --role-name $deployTag-ecsTaskExecution --assume-role-policy-document '{"Version": "2008-10-17","Statement": [{"Sid": "","Effect": "Allow","Principal": {"Service": "ecs-tasks.amazonaws.com"},"Action": "sts:AssumeRole"}]}' --region $awsRegion --profile $awsProfile | jq -r .Role.Arn)
echo "      $taskExecutionRoleARN"

# Attach AWS managed AmazonECSTaskExecutionRolePolicy to above IAM role
echo "6/27  Attaching AmazonECSTaskExecutionRolePolicy to $deployTag-ecsTaskExecution"
aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy --role-name $deployTag-ecsTaskExecution --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

# Create AWS log group
aws logs create-log-group --log-group-name /ecs/$deployTag-php-$nameSpace --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
aws logs create-log-group --log-group-name /ecs/$deployTag-nginx-$nameSpace --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

# Register task definitions
echo "7/27  Registering ECS Task Definitions php & nginx"
aws ecs register-task-definition --container-definitions '[{"name": "php-'$nameSpace'","image": "'$ecsRepositoryUri':php.'$nameSpace'","essential": true,"logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group": "/ecs/'$deployTag'-php-'$nameSpace'","awslogs-region": "'$awsRegion'","awslogs-stream-prefix": "ecs"}}}]' --family "php-$nameSpace" --requires-compatibilities "FARGATE"  --network-mode "awsvpc" --cpu "256" --memory "512" --task-role "$taskExecutionRoleARN" --execution-role-arn "$taskExecutionRoleARN" --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1
aws ecs register-task-definition --container-definitions '[{"name": "nginx-'$nameSpace'","image": "'$ecsRepositoryUri':nginx.'$nameSpace'","essential": true,"logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group": "/ecs/'$deployTag'-nginx-'$nameSpace'","awslogs-region": "'$awsRegion'","awslogs-stream-prefix": "ecs"}}, "portMappings": [{"hostPort": 80,"protocol": "tcp","containerPort": 80}]}]' --family "nginx-$nameSpace" --requires-compatibilities "FARGATE"  --network-mode "awsvpc" --cpu "256" --memory "512" --task-role "$taskExecutionRoleARN" --execution-role-arn "$taskExecutionRoleARN" --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

# Create VPC for Fargate cluster
echo "8/27  Creating VPC for Fargate cluster"
vpcId=$(aws ec2 create-vpc --cidr-block "10.0.0.0/16" --region $awsRegion --profile $awsProfile | jq -r .Vpc.VpcId)
echo "      $vpcId"

# Enable VPC DNS HOSTNAMES
aws ec2 modify-vpc-attribute --vpc-id $vpcId --enable-dns-hostnames "{\"Value\":true}" --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

#create internetgateway
echo "9/27  Creating Internet Gateway"
igwId=$(aws ec2 create-internet-gateway --region $awsRegion --profile $awsProfile | jq -r .InternetGateway.InternetGatewayId)
echo "      $igwId"

# Associate internetgateway with vpc
echo "10/27 Assosiating IGW with VPC"
aws ec2 attach-internet-gateway --internet-gateway-id $igwId --vpc-id $vpcId --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

# Get default route table id
echo "11/27 Getting default Route Table Id"
rtbId=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpcId" --region $awsRegion --profile $awsProfile | jq -r .RouteTables[0].RouteTableId)

# Add routetable 0.0.0.0/0 > igw
echo "12/27 Adding default route to Internet"
aws ec2 create-route --gateway-id $igwId --route-table-id $rtbId --destination-cidr-block 0.0.0.0/0 --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

# Create 2 Subnets for Fargate cluster
echo '13/27 Creating subnets in AZ '$awsRegion'a and '$awsRegion'b'
subnetId1=$(aws ec2 create-subnet --cidr-block "10.0.0.0/24" --vpc-id $vpcId --availability-zone $awsRegion'a' --region $awsRegion --profile $awsProfile | jq -r .Subnet.SubnetId)
subnetId2=$(aws ec2 create-subnet --cidr-block "10.0.1.0/24" --vpc-id $vpcId --availability-zone $awsRegion'b' --region $awsRegion --profile $awsProfile | jq -r .Subnet.SubnetId)
echo "      $subnetId1 $subnetId2"

# Create Security Group which will be shared among containers
echo "14/27 Creating Security Group for Fargate tasks"
securityGroupId=$(aws ec2 create-security-group --description "Security Group for Fargate Task" --group-name "$deployTag-fargatetasks" --vpc-id $vpcId --region $awsRegion --profile $awsProfile | jq -r .GroupId)
echo "      $securityGroupId"

# Add security group rules
echo "15/27 Adding security group rule allowing all traffic to and from security group itself"
aws ec2 authorize-security-group-ingress --group-id $securityGroupId --protocol "all" --port "-1" --source-group $securityGroupId --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

# Create Service Discovery name space required for Fargate PHP service
echo "16/27 Creating Service Discovery namespace: $nameSpace (this will take a while)"
nameSpaceOperationId=$(aws servicediscovery create-private-dns-namespace --name $nameSpace --vpc $vpcId --region $awsRegion --profile $awsProfile | jq -r .OperationId)
nameSpaceOperationStatus=$(aws servicediscovery get-operation --operation-id $nameSpaceOperationId --region $awsRegion --profile $awsProfile | jq -r .Operation.Status)
nameSpaceId=$(aws servicediscovery get-operation --operation-id $nameSpaceOperationId --region $awsRegion --profile $awsProfile | jq -r .Operation.Targets.NAMESPACE)

while [ $nameSpaceOperationStatus != "SUCCESS" ]; do
    echo "      - $nameSpaceOperationStatus $nameSpaceOperationId"
    sleep 10
    nameSpaceOperationStatus=$(aws servicediscovery get-operation --operation-id $nameSpaceOperationId --region $awsRegion --profile $awsProfile | jq -r .Operation.Status)
done
echo "      Namespace status is $nameSpaceOperationStatus and namespace Id is $nameSpaceId"

# Create Service Discovery service (servicename.namespace)
echo "17/27 Creating Service Discovery service named: php"
PHPregistryArn=$(aws servicediscovery create-service --name "php" --dns-config 'NamespaceId="'$nameSpaceId'",DnsRecords=[{Type="A",TTL="300"}]' --health-check-custom-config FailureThreshold=1 --region $awsRegion --profile $awsProfile | jq -r .Service.Arn)

# Create Fargate Cluster
echo "18/27 Creating Fargate cluster"
clusterArn=$(aws ecs create-cluster --cluster-name "$deployTag-fargatecluster" --region $awsRegion --profile $awsProfile | jq -r .cluster.clusterArn)
echo "      $clusterArn"

# Create Fargate Cluster PHP Service with Service Discovery
echo "19/27 Creating Fargate cluster Service named: php"
aws ecs create-service --cluster $clusterArn --service-name "php" --task-definition "php-$nameSpace" --desired-count 1 --service-registries '[{"registryArn":"'$PHPregistryArn'"}]' --launch-type "FARGATE" --network-configuration "awsvpcConfiguration={subnets=[$subnetId1,$subnetId2],securityGroups=[$securityGroupId],assignPublicIp=ENABLED}" --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

# Create Application Load Balancer for NGINX container
echo "20/27 Creating Application Load Balancer"
loadBalancerArn=$(aws elbv2 create-load-balancer --name "$deployTag-fargatealb" --subnets $subnetId1 $subnetId2 --security-groups $securityGroupId --scheme "internet-facing" --type "application" --ip-address-type "ipv4" --region $awsRegion --profile $awsProfile | jq -r .LoadBalancers[0].LoadBalancerArn)
echo "      $loadBalancerArn"

# Create security group for ALB
echo "21/27 Creating Security Group for ALB"
ALBsecurityGroupId=$(aws ec2 create-security-group --description "Security Group for Fargate ALB" --group-name "$deployTag-albsg" --vpc-id $vpcId --region $awsRegion --profile $awsProfile | jq -r .GroupId)
echo "      $ALBsecurityGroupId"

# Allow all incoming connections on tcp 80 for ALB
echo "22/27 Allow all incoming on tcp 80 for ALB"
aws ec2 authorize-security-group-ingress --group-id $ALBsecurityGroupId --protocol "tcp" --port "80" --cidr 0.0.0.0/0 --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

# Associate security group with ALB
echo "23/27 Associating security group with ALB"
aws elbv2 set-security-groups --load-balancer-arn $loadBalancerArn --security-groups $ALBsecurityGroupId $securityGroupId --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

# Allowing tcp 80 from ALB to Fargate tasks
aws ec2 authorize-security-group-ingress --group-id $securityGroupId --protocol "tcp" --port "80" --source-group $ALBsecurityGroupId --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

# Create target group for ALB
echo "24/27 Creating Target Group for Application Load Balancer"
nginxTargetGroupARN=$(aws elbv2 create-target-group --name "$deployTag-nginx-albtg" --protocol "HTTP" --port 80 --vpc-id "$vpcId" --target-type "ip" --region $awsRegion --profile $awsProfile | jq -r .TargetGroups[0].TargetGroupArn)

# Associate target group with load balancer
echo "25/27 Associating Target Group with Application Load Balancer"
aws elbv2 create-listener --load-balancer-arn $loadBalancerArn --protocol "HTTP" --port "80" --default-actions Type=forward,TargetGroupArn=$nginxTargetGroupARN --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

# Create Fargate Cluster NGINX Service with Application Load Balancer
echo "26/27 Creating fargate cluster Service named: nginx"
aws ecs create-service --cluster $clusterArn --service-name "nginx" --task-definition "nginx-$nameSpace" --desired-count 1 --load-balancers "targetGroupArn=$nginxTargetGroupARN,containerName=nginx-$nameSpace,containerPort=80" --launch-type "FARGATE" --network-configuration "awsvpcConfiguration={subnets=[$subnetId1,$subnetId2],securityGroups=[$securityGroupId],assignPublicIp=ENABLED}" --region $awsRegion --profile $awsProfile >>./deploy.log 2>&1

echo "27/27 Getting URL for Aplication Load Balancer"
loadBalancerDns=$(aws elbv2 describe-load-balancers --load-balancer-arns $loadBalancerArn  --region $awsRegion --profile $awsProfile | jq -r .LoadBalancers[0].DNSName)
echo "

    http://$loadBalancerDns
    
"