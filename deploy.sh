#!/usr/bin/env bash
# Стек с нуля одной командой: bash deploy.sh <версия>
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${1:?укажите версию: bash deploy.sh 5.0}
[[ "$VERSION" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || exit 2
PREFIX=ionov-01
PORT=8003
REGISTRY=localhost:6001
IMAGE=$REGISTRY/$PREFIX/probe:$VERSION

# 1. Режим Swarm: включить, если он выключен.
#    Состояние: docker info --format '{{.Swarm.LocalNodeState}}' — active или inactive.
if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != active ]; then
  docker swarm init --advertise-addr eth0
fi
docker node ls > /dev/null
if docker service inspect "$PREFIX"_web > /dev/null 2>&1; then
  [ "$(docker service inspect "$PREFIX"_web -f '{{index .Spec.Labels "devops.homework"}}')" = 2 ] || {
    echo 'Имя стека занято другой работой.' >&2; exit 1;
  }
fi

# 2. Свой реестр: создать контейнер registry:2, если его ещё нет.
#    Есть ли он: docker ps -a --format '{{.Names}}' | grep -qx "$PREFIX-registry"
if docker container inspect "$PREFIX-registry" > /dev/null 2>&1; then
  [ "$(docker inspect "$PREFIX-registry" -f '{{index .Config.Labels "devops.homework"}}')" = 2 ] || {
    echo 'Имя реестра занято другой работой.' >&2; exit 1;
  }
  if [ "$(docker inspect "$PREFIX-registry" -f '{{.State.Running}}')" != true ]; then
    docker start "$PREFIX-registry"
  fi
else
  docker volume create --label devops.homework=2 ionov-01-homework2-registry
  docker run -d --name "$PREFIX-registry" --label devops.homework=2 \
    --restart unless-stopped -p 6001:5000 \
    -v ionov-01-homework2-registry:/var/lib/registry registry:2
fi
SECONDS=0
until curl -sf -m 2 "$REGISTRY/v2/" > /dev/null; do
  [ "$SECONDS" -lt 90 ] || { echo 'Реестр не ответил за 90 секунд.' >&2; exit 1; }
  sleep 1
done

# 3. Образ: собрать с версией $VERSION и отправить в реестр.
docker build --build-arg VERSION="$VERSION" -t "$IMAGE" .
docker push "$IMAGE"

# 4. Стек: развернуть stack.yaml, передав в него VERSION.
VERSION="$VERSION" docker stack deploy --detach=false --resolve-image changed -c stack.yaml "$PREFIX"

# 5. Дождаться ответа приложения, не дольше 90 секунд.
SECONDS=0
until curl -sf -m 2 "127.0.0.1:$PORT/notes" > /dev/null; do
  if [ $SECONDS -ge 90 ]; then echo "приложение не ответило за 90 секунд" >&2; exit 1; fi
  sleep 2
done
curl -fsS "127.0.0.1:$PORT/notes"; echo
