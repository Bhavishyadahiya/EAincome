#!/bin/bash

CONTAINER_FILE="containernames.txt"

# Check Docker
if ! command -v docker &>/dev/null; then
  echo "Docker is not installed or not in PATH."
  exit 1
fi

# Check container file
if [ ! -f "$CONTAINER_FILE" ]; then
  echo "Container names file '$CONTAINER_FILE' not found."
  exit 1
fi

echo "Restarting EarnApp containers..."

FOUND=false

while read -r container; do
  if docker inspect "$container" >/dev/null 2>&1; then
    echo "Restarting: $container"
    docker restart "$container"
    FOUND=true
  else
    echo "Skipping (not found): $container"
  fi
done < "$CONTAINER_FILE"

if [ "$FOUND" = false ]; then
  echo "No running EarnApp containers found."
  exit 1
fi

echo "All containers restarted."
exit 0
