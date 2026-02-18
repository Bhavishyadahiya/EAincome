#!/bin/bash

CONTAINER_FILE="containernames.txt"

if [[ "$1" != "--restart" || -z "$2" ]]; then
  echo "Usage:"
  echo "  $0 --restart <container-name-prefix>"
  echo
  echo "Example:"
  echo "  $0 --restart earnapp"
  exit 1
fi

PREFIX="$2"

# Safety checks
if ! command -v docker &>/dev/null; then
  echo "Docker is not installed or not in PATH."
  exit 1
fi

if [ ! -f "$CONTAINER_FILE" ]; then
  echo "Container names file '$CONTAINER_FILE' not found."
  exit 1
fi

MATCHED=false

for container in $(grep -E "^${PREFIX}" "$CONTAINER_FILE"); do
  if docker inspect "$container" >/dev/null 2>&1; then
    echo "Restarting container: $container"
    docker restart "$container"
    MATCHED=true
  else
    echo "Container not found (skipping): $container"
  fi
done

if [ "$MATCHED" = false ]; then
  echo "No containers found with prefix: $PREFIX"
  exit 1
fi

echo "Done."
exit 0
