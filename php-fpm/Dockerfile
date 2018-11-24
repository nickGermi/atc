# php-fpm/Dockerfile
FROM php:7.0-fpm-alpine

# Required for PHP FPM sock
RUN addgroup -g 3000 -S app
RUN adduser -u 3000 -S -D -G app app

# In real world we could create a shared data volume
# or application container along with symlinks
RUN mkdir /www/ /www/app/
RUN echo "<?php phpinfo();" > /www/app/index.php

# copy configuration files
COPY ./etc /usr/local/etc
