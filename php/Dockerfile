# php/Dockerfile
FROM php:7.0-fpm-alpine

EXPOSE 9000

RUN mkdir /www/ /www/app/
RUN echo "<?php phpinfo();" > /www/app/index.php