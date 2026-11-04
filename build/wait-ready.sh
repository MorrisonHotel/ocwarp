#!/bin/sh
# Ждать, пока kill-switch применён в ЭТОМ netns: ocwarp-netns пишет в ready
# идентификатор своего netns, он совпадает с нашим только в общей сети.
# Нужно при старте демона Docker: порядок запуска контейнеров там произвольный.
until [ "$(cat /state/ready 2>/dev/null)" = "$(readlink /proc/self/ns/net)" ]; do
  sleep 1
done
