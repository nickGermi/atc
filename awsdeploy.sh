#!/bin/bash

#variables
awsRegion="us-east-1"
awsProfile="default"
ecsRepositoryName="example"
nameSpace="example"
iamRolePrefix="example"
fargateClusterName="example"

# Create ECS Repository and tag docker images with ecsRepositoryUri
ecsRepositoryUri=$(aws ecr create-repository --repository-name $ecsRepositoryName --region $awsRegion --profile $awsProfile | jq -r .repository.repositoryUri)
docker build -t $ecsRepositoryUri:nginx.example ./nginx
docker build -t $ecsRepositoryUri:php.example ./php

# Obtain aws credentials and push docker images
$(aws ecr get-login --no-include-email --region $awsRegion --profile $awsProfile)
docker push $ecsRepositoryUri:nginx.example
docker push $ecsRepositoryUri:php.example

# Create required IAM Roles
taskExecutionRoleARN=$(aws iam create-role --role-name $iamRolePrefix-ecsTaskExecution --assume-role-policy-document file://./taskExecutionRolePolicy.json --region $awsRegion --profile $awsProfile | jq -r .Role.Arn)

# Attach AWS managed AmazonECSTaskExecutionRolePolicy to above IAM role
aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy --role-name $iamRolePrefix-ecsTaskExecution --region $awsRegion --profile $awsProfile

# Register task definitions
aws ecs register-task-definition --container-definitions '[{"name": "php-example","image": "'$ecsRepositoryUri':php.example","essential": true}]' --family "php-example" --requires-compatibilities "FARGATE"  --network-mode "awsvpc" --cpu "256" --memory "512" --task-role "$taskExecutionRoleARN" --execution-role-arn "$taskExecutionRoleARN" --region $awsRegion --profile $awsProfile
aws ecs register-task-definition --container-definitions '[{"name": "nginx-example","image": "'$ecsRepositoryUri':nginx.example","essential": true, "portMappings": [{"hostPort": 80,"protocol": "tcp","containerPort": 80}]}]' --family "nginx-example" --requires-compatibilities "FARGATE"  --network-mode "awsvpc" --cpu "256" --memory "512" --task-role "$taskExecutionRoleARN" --execution-role-arn "$taskExecutionRoleARN" --region $awsRegion --profile $awsProfile

# Create VPC for Fargate cluster
vpcId=$(aws ec2 create-vpc --cidr-block "10.0.0.0/16" --region $awsRegion --profile $awsProfile | jq -r .Vpc.VpcId)

#create internetgateway
#associate internetgateway with vpc
#add routetable 0.0.0.0/0 > igw

# Create 2 Subnets for Fargate cluster
subnetId1=$(aws ec2 create-subnet --cidr-block "10.0.0.0/24" --vpc-id $vpcId --availability-zone $awsRegion'a' --region $awsRegion --profile $awsProfile | jq -r .Subnet.SubnetId)
subnetId2=$(aws ec2 create-subnet --cidr-block "10.0.1.0/24" --vpc-id $vpcId --availability-zone $awsRegion'b' --region $awsRegion --profile $awsProfile | jq -r .Subnet.SubnetId)

# Create Security Group which will be shared among containers
securityGroupId=$(aws ec2 create-security-group --description "example" --group-name "example" --vpc-id $vpcId --region $awsRegion --profile $awsProfile | jq -r .GroupId)

# Add security group rules
aws ec2 authorize-security-group-ingress --group-id $securityGroupId --protocol "all" --port "-1" --source-group $securityGroupId --region $awsRegion --profile $awsProfile

# Create Service Discovery name space required for Fargate PHP service
nameSpaceOperationId=$(aws servicediscovery create-private-dns-namespace --name $nameSpace --vpc $vpcId --region $awsRegion --profile $awsProfile | jq -r .OperationId)
nameSpaceOperationStatus=$(aws servicediscovery get-operation --operation-id $nameSpaceOperationId --region $awsRegion --profile $awsProfile | jq -r .Operation.Status)
nameSpaceId=$(aws servicediscovery get-operation --operation-id $nameSpaceOperationId --region $awsRegion --profile $awsProfile | jq -r .Operation.Targets.NAMESPACE)

while [ $nameSpaceOperationStatus != "SUCCESS" ]; do
    echo "Service Discovery name space creation operation ID $nameSpaceOperationId : $nameSpaceOperationStatus"
    sleep 5
    nameSpaceOperationStatus=$(aws servicediscovery get-operation --operation-id $nameSpaceOperationId --region $awsRegion --profile $awsProfile | jq -r .Operation.Status)
done

# Create Service Discovery service (servicename.namespace)
PHPregistryArn=$(aws servicediscovery create-service --name "php" --dns-config 'NamespaceId="'$nameSpaceId'",DnsRecords=[{Type="A",TTL="300"}]' --health-check-custom-config FailureThreshold=1 --region $awsRegion --profile $awsProfile | jq -r .Service.Arn)

# Create Fargate Cluster
clusterArn=$(aws ecs create-cluster --cluster-name "$fargateClusterName" --region $awsRegion --profile $awsProfile | jq -r .cluster.clusterArn)

# Create Fargate Cluster PHP Service with Service Discovery
aws ecs create-service --cluster $clusterArn --service-name "php-example" --task-definition "php-example" --desired-count 1 --service-registries '[{"registryArn":"'$PHPregistryArn'"}]' --launch-type "FARGATE" --network-configuration "awsvpcConfiguration={subnets=[$subnetId1,$subnetId2],securityGroups=[$securityGroupId],assignPublicIp=ENABLED}" --region $awsRegion --profile $awsProfile

# Create Fargate Cluster NGINX Service with Application Load Balancer
aws ecs create-service --service-name "nginx-example" --task-definition "nginx-example" --desired-count 1 --loadBalancers '"loadBalancerName":"fargate-alb","containerName":"php-example","containerPort":80'

# Create Application Load Balancer for NGINX container
loadBalancerArn=$(aws elbv2 create-load-balancer --name "fargate-alb" --subnets $subnetId1 $subnetId2 --security-groups $securityGroupId --scheme "internet-facing" --type "application" --ip-address-type "ipv4" --region $awsRegion --profile $awsProfile | jq -r .LoadBalancers.DNSName)
nginxTargetGroupARN=$(aws elbv2 create-target-group --name "nginx-example" --protocol "HTTP" --port 80 --vpc-id "$vpcId" --target-type "ip" --region $awsRegion --profile $awsProfile | jq -r .TargetGroups.TargetGroupArn)

# Associate target group with load balancer
aws elbv2 create-listener --load-balancer-arn $loadBalancerArn --protocol "HTTP" --port "80" --default-actions Type=forward,TargetGroupArn=$nginxTargetGroupARN --region $awsRegion --profile $awsProfile
aws ecs create-service --cluster $clusterArn --service-name "nginx-example" --task-definition "nginx-example" --desired-count 1 --load-balancers "targetGroupArn=$nginxTargetGroupARN,containerName=nginx-example,containerPort=80" --launch-type "FARGATE" --network-configuration "awsvpcConfiguration={subnets=[$subnetId1,$subnetId2],securityGroups=[$securityGroupId],assignPublicIp=ENABLED}" --region $awsRegion --profile $awsProfile
