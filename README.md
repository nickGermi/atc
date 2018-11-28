# ATC

NGINX & PHP-FPM Docker containers

Configure 2 docker containers as seperate fargate tasks on private subnets and an Internet facing Aplication Load Balancer on public subnets

## Getting Started

These instructions will get you a copy of the project up and running on your local development machine and testing purposes. See deployment for notes on how to deploy the project on AWS.

### Local Dev Setup

#### Prerequisites

```
docker 18.0+
```

Make sure you have Docker engine & CLI installed on your host
To launch your enviroment run

```
docker-compose up
```

Application will be accessible via

```
http://localhost
```

To stop run

```
docker-compose down
```

## Deploy to AWS Fargate

#### Prerequisites

```
docker 18.0+
AWS CLI 1.16+
jq
AWS CLI running with IAM permissions for following services:
- IAM
- EC2
- SERVICEDISCOVERY
- VPC
- ECS
- ECR
...
```

To execute run

```
chmod +x ./awsdeploy.sh
./awsdeploy.sh
```

CloudWatch logs
```
/ecs/<deploytag>-nginx-demo
/ecs/<deploytag>-php-demo
```

What awsdeploy script does:

```
- Creates a VPC with 2 private subnets and 1 public subnet with a NAT and IGW and appropriate routes
- Creates a new ECS respository
- Tags docker images with ECS repository URI
- Pushes docker images into ECS repository
- Creates CloudWatch log groups
- Creates ECS Fargate cluster
- Creates ECS Task Definition
- Create Service Discovery namespace
- Creates cluster services in private subnets without public IP
- Creates Application Load Balancer to server requests on TCP 80
```

To do:

```
Check status of ALB before showing URL
```