# php/Dockerfile
FROM php:7.2-fpm-alpine

RUN mkdir /www/ /www/app/
RUN echo "<?php phpinfo();" > /www/app/index.php

STOPSIGNAL SIGTERM