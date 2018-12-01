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

    Deployment tag is $deployTag
"

# Create ECS Repository and tag docker images with ecsRepositoryUri
echo "Creating ECS Repository $deployTag-fargaterepo"
ecsRepositoryUri=$(aws ecr create-repository --repository-name $deployTag-fargaterepo --region $awsRegion --profile $awsProfile | jq -r .repository.repositoryUri)
echo "      $ecsRepositoryUri" >> ./deploy.log
echo "Building and tagging Docker images..."
docker build -t $ecsRepositoryUri:nginx.$nameSpace ./nginx
docker build -t $ecsRepositoryUri:php.$nameSpace ./php
# Obtain aws credentials for docker
echo "Obtaining credentials for docker push"
aws ecr get-login --no-include-email --region $awsRegion --profile $awsProfile | awk '{printf $6}' | docker login -u AWS $ecsRepositoryUri --password-stdin
# Push docker images to AWS Repo
echo "Pushing Docker images..."
docker push $ecsRepositoryUri:nginx.$nameSpace
docker push $ecsRepositoryUri:php.$nameSpace
echo "Images:
    $ecsRepositoryUri:nginx.$nameSpace
    $ecsRepositoryUri:php.$nameSpace
"
echo "Deploying infra via CloudFormation"

stackId=$(aws cloudformation create-stack --stack-name fargate-$deployTag \
   --template-body file://awscfn.template \
   --parameters ParameterKey=NginxImage,ParameterValue=$ecsRepositoryUri:nginx.$nameSpace ParameterKey=PhpImage,ParameterValue=$ecsRepositoryUri:php.$nameSpace \
   --capabilities CAPABILITY_IAM --region $awsRegion --profile $awsProfile | jq -r .StackId)

#check stack status and look for output
stackStatus=$(aws cloudformation describe-stacks --stack-name fargate-$deployTag --region $awsRegion --profile $awsProfile | jq -r .Stacks[0].StackStatus)

while [ $stackStatus != "CREATE_COMPLETE" ]; do
    echo "$stackStatus $stackId"
    sleep 30
    stackStatus=$(aws cloudformation describe-stacks --stack-name fargate-$deployTag --region $awsRegion --profile $awsProfile | jq -r .Stacks[0].StackStatus)
done
echo "Stack status is $stackStatus"
stackOutput=$(aws cloudformation describe-stacks --stack-name fargate-$deployTag --region $awsRegion --profile $awsProfile | jq -r .Stacks[0].Outputs[0].OutputValue)
echo "ALB URL: $stackOutput"