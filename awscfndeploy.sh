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