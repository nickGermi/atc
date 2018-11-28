# nginx/Dockerfile
FROM nginx:1.14-alpine

EXPOSE 80

RUN mkdir /www/ /www/app/
RUN echo "<?php phpinfo();" > /www/app/index.php

# copy configuration files
COPY /site.conf /etc/nginx/conf.d/default.conf

STOPSIGNAL SIGTERM

CMD ["nginx", "-g", "daemon off;"]