#!/bin/sh

project_name=$1
service_name=$2
docker_compose_files=$3
other_services=$4

echo $docker_compose_files

old_container_id=$(docker ps -f name="$project_name-$service_name" -q | tail -n1)

if [ "$old_container_id" = "" ]; then
  docker compose $docker_compose_files up -d
  exit 0;
fi

docker compose $docker_compose_files pull

docker compose $docker_compose_files up -d $other_services

# bring a new container online, running new code
# (traefik continues routing to the old container only)
echo "Starting new container"
docker compose $docker_compose_files up -d --no-deps --scale "$service_name"=2 --no-recreate "$service_name"

# wait for new container to be available
new_container_id=$(docker ps -f name="$project_name-$service_name" -q | head -n1)
healthcheck_interval=$(docker inspect "$new_container_id" --format="{{if .Config.Healthcheck}}{{if .Config.Healthcheck.Interval}}{{.Config.Healthcheck.Interval}}{{else}}30s{{end}}{{end}}")
healthcheck_start_period=$(docker inspect "$new_container_id" --format="{{if .Config.Healthcheck}}{{if .Config.Healthcheck.StartPeriod}}{{.Config.Healthcheck.StartPeriod}}{{else}}30s{{end}}{{end}}")

sleep "$healthcheck_start_period"

i=1
max=6
while [ $i -lt $max ]
do
    echo "Checking new container has started, attempt $i/5..."
    healthcheck_status=$(docker inspect "$new_container_id" --format="{{if .State.Health}}{{.State.Health.Status}}{{end}}")
    echo "Health status: $healthcheck_status"

    if [ "$healthcheck_status" = "healthy" ]; then
      break
    fi

    sleep "$healthcheck_interval"
    i=$((i+1))
done

exit_code=0
if [ "$healthcheck_status" = "healthy" ]; then
  # take the old container offline
  docker stop "$old_container_id" > /dev/null
  docker rm "$old_container_id" > /dev/null
else
  # take the new container offline
  docker stop "$new_container_id" > /dev/null
  docker rm "$new_container_id" > /dev/null

  exit_code=1
fi

docker compose $docker_compose_files up -d --no-deps --scale "$service_name"=1 --no-recreate "$service_name"
exit $exit_code