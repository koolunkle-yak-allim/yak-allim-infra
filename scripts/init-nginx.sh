#!/usr/bin/env bash

# 블루-그린 배포가 덮어쓰는 nginx/conf.d/service-url.inc는 git에서 추적하지 않으므로,
# 처음 구동할 때 기본값(blue)으로 만들어 둔다. 네트워크와 볼륨은 docker compose가 만든다.
if [ ! -f "nginx/conf.d/service-url.inc" ]; then
    echo "Creating default nginx/conf.d/service-url.inc..."
    cp nginx/conf.d/service-url.inc.example nginx/conf.d/service-url.inc
else
    echo "nginx/conf.d/service-url.inc already exists."
fi
