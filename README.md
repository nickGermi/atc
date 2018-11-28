# ATC

NGINX & PHP-FPM Docker containers

## Getting Started

These instructions will get you a copy of the project up and running on your local development machine and testing purposes. See deployment for notes on how to deploy the project on a live system.

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
- Creates a new ECS respository
- Tags docker images with ECS repository URI
- Pushes docker images into ECS repository
- Creates VPC, IGW, 2 subnets in 2 AZs, enables DNS support and hostname
- Creates CloudWatch log groups
- Creates ECS Fargate cluster
- Creates ECS Task Definition
- Create Service Discovery namespace
- Creates cluster services
```