# nginx-backend/Dockerfile
FROM nginx:1.13-alpine

EXPOSE 80

# Required for PHP FPM sock
RUN addgroup -g 3000 -S app && adduser -u 3000 -S -G app app

# In real world we could create a shared data volume
# or application container along with symlinks
RUN mkdir /www/ /www/app/
RUN echo "<?php phpinfo();" > /www/app/index.php

# copy configuration files
COPY /etc /etc