# ATC

NGINX & PHP-FPM Docker containers

## Getting Started

These instructions will get you a copy of the project up and running on your local development machine and testing purposes. See deployment for notes on how to deploy the project on a live system.

### Prerequisites

What things you need to install the software and how to install them

```
docker 18.0+
AWS CLI 1.16+
jq
```

### Local Dev Setup

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

To execute run

```
chmod +x ./awsdeploy.sh
./awsdeploy.sh
```

What awsdeploy script does:

```
- Creates a new ECS respository
- Tags docker images with ECS repository URI
- Pushes docker images into ECS repository
- Creates ECS Fargate cluster
- Creates ECS Task Definition
- Create Service Discovery namespace
- Creates cluster services
```

To do:

```
Create security group for ALB
Add security rule ingress all port tcp 80
Add CloudWatch log capability to Task Definitions
```

Known issues:

```
NGINX fargate service fails to reach php.demo hence it automatically stops and loops
```