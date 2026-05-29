set -o pipefail

################################################################################
# Interactive Session Service Starter - NGENCERF
#
# Purpose: Start the NGENCERF application stack (nginx proxy, SLURM wrapper
#          Flask app, ngencerf-server and ngencerf-ui Docker containers)
# Runs on: Controller or compute node
#
# Required Environment Variables (from inputs.sh):
#   - service_port: Allocated port (injected by session_runner)
#   - service_parent_install_dir: Installation directory
#   - service_nginx_sif: Path to NGINX unprivileged Singularity container
#   - nwm_cal_mgr_singularity_container_path: nwm-cal-mgr Singularity container
#   - nwm_fcst_mgr_singularity_container_path: nwm-fcst-mgr Singularity container
#   - nwm_verf_singularity_container_path: nwm-verf Singularity container
#   - local_data_dir: Path to data directory on shared filesystem
#   - container_data_dir: Path to data directory inside containers
#   - service_ngencerf_server_dir: Path to ngencerf-server repository
#   - service_ngencerf_ui_dir: Path to ngencerf-ui repository
#   - service_build_server: Rebuild server image (true/false)
#   - service_build_ui: Rebuild UI image (true/false)
#   - service_slurm_app_workers: Gunicorn worker count
#   - service_only_connect: Skip launch, connect to existing service (true/false)
#   - service_name: Docker compose project name (ngencerf)
################################################################################

set -x

echo "whoami: $(whoami)"

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

# Port 5000 is used by the SLURM wrapper Flask app (internal, not user-facing).
# Only one NGENCERF session can run per node.
PORT=5000
if lsof -i :$PORT >/dev/null 2>&1; then
    echo "::error title=Error::Port ${PORT} is already in use. Ensure no other NGENCERF session is running on this node."
    exit 1
fi

# Docker operations and file ownership changes require passwordless sudo.
if sudo -n true 2>/dev/null; then
    echo "Passwordless sudo available."
else
    echo "::error title=Error::Passwordless sudo is required for NGENCERF. Exiting."
    exit 1
fi

# Determine SLURM job metrics format based on SLURM version.
# The Flask app exports this so sacct output format matches the scheduler version.
slurm_version=$(scontrol version 2>/dev/null | awk '{print $2}' | cut -d'.' -f1)
if [[ "$slurm_version" == 22* ]]; then
    export SLURM_JOB_METRICS="JobID,Elapsed,NCPUS,CPUTime,MaxRSS,MaxDiskRead,MaxDiskWrite,Reserved"
else
    export SLURM_JOB_METRICS="JobID,Elapsed,NCPUS,CPUTime,MaxRSS,MaxDiskRead,MaxDiskWrite,Planned"
fi

# ngencerf-ui Docker compose exposes the UI on port 3000 (hardcoded in compose files).
ngencerf_port=3000

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
echo "echo '$(date) Running cancel script'" >> cancel.sh
chmod +x cancel.sh

if [[ "${service_only_connect}" == "true" ]]; then
    echo "::notice::Connecting to existing NGENCERF service on port ${ngencerf_port}"
    sleep inf
fi

# Validate required Singularity containers
if ! [ -f "${service_nginx_sif}" ]; then
    echo "::error title=Error::NGINX proxy Singularity container not found: ${service_nginx_sif}"
    exit 1
fi
if ! [ -f "${nwm_cal_mgr_singularity_container_path}" ]; then
    echo "::error title=Error::nwm-cal-mgr Singularity container not found: ${nwm_cal_mgr_singularity_container_path}"
    exit 1
fi
if ! [ -f "${nwm_fcst_mgr_singularity_container_path}" ]; then
    echo "::error title=Error::nwm-fcst-mgr Singularity container not found: ${nwm_fcst_mgr_singularity_container_path}"
    exit 1
fi
if ! [ -f "${nwm_verf_singularity_container_path}" ]; then
    echo "::error title=Error::nwm-verf Singularity container not found: ${nwm_verf_singularity_container_path}"
    exit 1
fi


#################
# NGINX WRAPPER #
#################
echo "::group::Nginx Proxy"
echo "Starting nginx on service_port=${service_port}, proxying ngencerf-ui on port ${ngencerf_port}"

# Nginx site config: routes / → ngencerf-ui, /api/ → ngencerf-server
cat >> config.conf <<HERE
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }

server {
  listen ${service_port};
  server_name _;
  index index.html index.htm index.php;
  client_max_body_size 0;

  proxy_connect_timeout 10s;
  proxy_send_timeout    600s;
  proxy_read_timeout    600s;
  send_timeout          600s;

  add_header Access-Control-Allow-Origin  \$http_origin always;
  add_header Vary                         Origin always;
  add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
  add_header Access-Control-Allow-Headers "Authorization,Content-Type,Accept,Origin,User-Agent,DNT,Cache-Control,X-Mx-ReqToken,Keep-Alive,X-Requested-With,If-Modified-Since" always;

  location / {
    proxy_pass http://127.0.0.1:${ngencerf_port}${basepath}/;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade    \$http_upgrade;
    proxy_set_header   Connection \$connection_upgrade;
    proxy_set_header   X-Real-IP         \$remote_addr;
    proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto \$scheme;
    proxy_set_header   X-Forwarded-Host  \$host;
    proxy_set_header   Host              \$host;
    if (\$request_method = OPTIONS) { return 204; }
  }

  location /api/ {
    proxy_pass http://127.0.0.1:8000/;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade    \$http_upgrade;
    proxy_set_header   Connection \$connection_upgrade;
    proxy_set_header   X-Real-IP         \$remote_addr;
    proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto \$scheme;
    proxy_set_header   X-Forwarded-Host  \$host;
    proxy_set_header   Host              \$host;
    if (\$request_method = OPTIONS) { return 204; }
  }
}
HERE

cat >> nginx.conf <<HERE
worker_processes  2;
error_log  /var/log/nginx/error.log notice;
pid        /tmp/nginx.pid;

events {
    worker_connections  1024;
}

http {
    proxy_temp_path /tmp/proxy_temp;
    client_body_temp_path /tmp/client_temp;
    fastcgi_temp_path /tmp/fastcgi_temp;
    uwsgi_temp_path /tmp/uwsgi_temp;
    scgi_temp_path /tmp/scgi_temp;

    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;
    sendfile        on;
    keepalive_timeout  65;
    include /etc/nginx/conf.d/*.conf;
}
HERE

mkdir -p ./tmp
touch empty
singularity run \
    -B $PWD/tmp:/tmp \
    -B $PWD/config.conf:/etc/nginx/conf.d/config.conf \
    -B $PWD/nginx.conf:/etc/nginx/nginx.conf \
    -B empty:/etc/nginx/conf.d/default.conf \
    ${service_nginx_sif} >> nginx.logs 2>&1 &
echo "kill $!" >> cancel.sh
echo "::endgroup::"


##################################
# LAUNCH SLURM WRAPPER FLASK APP #
##################################
echo "::group::SLURM Wrapper App"

SLURM_APP_VENV=${service_parent_install_dir}/ngencerf-venv
GUNICORN_BIN=${SLURM_APP_VENV}/bin/gunicorn

if ! [ -f "${GUNICORN_BIN}" ]; then
    echo "::error title=Error::Gunicorn not found at ${GUNICORN_BIN}. The controller script must run first."
    exit 1
fi

# Copy scripts to the job rundir and substitute the local_data_dir placeholder.
# The Flask app uses ./run_callback.sh relative to its working directory.
NGENCERF_DIR=${PW_PARENT_JOB_DIR}/ngencerf
cp ${NGENCERF_DIR}/slurm-wrapper-app-v3.py .
cp ${NGENCERF_DIR}/run_callback.sh .
sed -i "s|__LOCAL_DATA_DIR__|${local_data_dir}|g" run_callback.sh
chmod +x run_callback.sh
cp ${NGENCERF_DIR}/run_pending_callbacks.sh .
sed -i "s|__LOCAL_DATA_DIR__|${local_data_dir}|g" run_pending_callbacks.sh
chmod +x run_pending_callbacks.sh

# PARTITIONS is read by the Flask app at startup to validate partition inputs.
export PARTITIONS=$(scontrol show partition | awk -F '=' '/^PartitionName=/ {printf "%s,", $2}' | sed 's/,$//')

${GUNICORN_BIN} \
    -w ${service_slurm_app_workers} \
    -b 0.0.0.0:5000 \
    slurm-wrapper-app-v3:app \
    --access-logfile slurm-wrapper-app-v3.log \
    --error-logfile slurm-wrapper-app-v3.log \
    --capture-output \
    --enable-stdio-inheritance > slurm-wrapper-app-v3.log 2>&1 &
slurm_wrapper_pid=$!
echo "kill ${slurm_wrapper_pid}" >> cancel.sh

# Re-run callbacks that were pending when the previous session ended
bash run_pending_callbacks.sh >> run_pending_callback.log 2>&1 &
run_pending_callbacks_pid=$!
echo "kill ${run_pending_callbacks_pid}" >> cancel.sh

echo "::endgroup::"


##########################
# LAUNCH NGENCERF APP    #
##########################
echo "::group::NGENCERF App"

# Add compose teardown to cancel script before launching containers
echo "cd ${service_ngencerf_server_dir}" >> cancel.sh
echo "docker compose \
  --project-name ${service_name} \
  --project-directory ${service_ngencerf_server_dir} \
  --env-file ${service_ngencerf_server_dir}/cerfServer/.env-override \
  --file ${service_ngencerf_server_dir}/production-pw.yaml \
  down --remove-orphans" >> cancel.sh

# Ensure docker buildx uses the plain docker driver, not docker-container.
# The docker-container driver requires a running daemon-in-daemon which is not
# available in all cluster environments.
if docker buildx ls | grep -qE 'localdocker.+docker.+\*'; then
    : # already selected
elif docker buildx ls | grep -q 'localdocker'; then
    docker buildx use localdocker
else
    docker buildx create --name localdocker --driver docker --use
fi

# ngencerf-ui compose files read these variables from the environment
export pw_platform_host="${PW_PLATFORM_HOST}"
export basepath="${basepath}"
export ngencerf_port="${ngencerf_port}"
export HOSTNAME=$(hostname)

# Determine image tags from git metadata in each repo directory
export NGENCERF_SERVER_TAG=$(
    cd ${service_ngencerf_server_dir} &&
    TAG=$(git describe --tags --exact-match 2>/dev/null)
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ -n "$TAG" ]; then
        echo "$TAG"
    elif [ "$BRANCH" == "development" ]; then
        echo "latest"
    elif [ "$BRANCH" != "HEAD" ]; then
        echo "$BRANCH"
    else
        git rev-parse --short HEAD
    fi
)
echo "Using NGENCERF_SERVER_TAG: $NGENCERF_SERVER_TAG"

export NGENCERF_UI_TAG=$(
    cd "${service_ngencerf_ui_dir}" &&
    TAG=$(git describe --tags --exact-match 2>/dev/null)
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ -n "$TAG" ]; then
        echo "$TAG"
    elif [ "$BRANCH" == "development" ]; then
        echo "latest"
    elif [ "$BRANCH" != "HEAD" ]; then
        echo "$BRANCH"
    else
        git rev-parse --short HEAD
    fi
)
echo "Using NGENCERF_UI_TAG: $NGENCERF_UI_TAG"

# Suppress the expected orphan warning when using multi-file compose projects
export COMPOSE_IGNORE_ORPHANS=True

# production-pw.yaml requires these for volume mounts that are not in .env-override
export NGEN_CAL_DATA_PATH=${local_data_dir}
export CONTAINER_PATH=$(dirname "${nwm_cal_mgr_singularity_container_path}")

if [[ "${service_build_server}" == "true" ]]; then
    CACHE_BUST=$(date +%s) docker compose \
        --project-name ${service_name} \
        --project-directory ${service_ngencerf_server_dir} \
        --env-file ${service_ngencerf_server_dir}/cerfServer/.env-override \
        --file ${service_ngencerf_server_dir}/production-pw.yaml \
        up --detach --build ngencerf-services
else
    CACHE_BUST=$(date +%s) docker compose \
        --project-name ${service_name} \
        --project-directory ${service_ngencerf_server_dir} \
        --env-file ${service_ngencerf_server_dir}/cerfServer/.env-override \
        --file ${service_ngencerf_server_dir}/production-pw.yaml \
        up --detach --no-build --pull never ngencerf-services
fi

# Generate a compose override to inject the dynamic basepath into the Nuxt server.
# NUXT_APP_BASE_URL tells Nitro (SSR runtime) to serve at the basepath, so
# asset URLs in rendered HTML are prefixed correctly for the platform proxy.
cat > ${PW_PARENT_JOB_DIR}/ui-compose-override.yml <<EOF
services:
  ngencerf-app:
    environment:
      - NUXT_APP_BASE_URL=${basepath}/
EOF

if [[ "${service_build_ui}" == "true" ]]; then
    docker compose \
        --project-name ${service_name} \
        --project-directory ${service_ngencerf_ui_dir} \
        --file ${service_ngencerf_ui_dir}/compose.yaml \
        --file ${PW_PARENT_JOB_DIR}/ui-compose-override.yml \
        up --detach --build --no-deps ngencerf-app
else
    docker compose \
        --project-name ${service_name} \
        --project-directory ${service_ngencerf_ui_dir} \
        --file ${service_ngencerf_ui_dir}/compose.yaml \
        --file ${PW_PARENT_JOB_DIR}/ui-compose-override.yml \
        up --detach --no-build --pull never --no-deps ngencerf-app
fi

# Extract the ngencerf CLI binary from the server image for use on the host
ngencerf_image="$(docker compose \
    --project-name ${service_name} \
    --project-directory ${service_ngencerf_server_dir} \
    --env-file ${service_ngencerf_server_dir}/cerfServer/.env-override \
    --file ${service_ngencerf_server_dir}/production-pw.yaml \
    config | awk '/ngencerf-services/{flag=1} flag && /image:/{print $2; exit}')"
echo "ngencerf_image=${ngencerf_image}"

docker rm -f extract >/dev/null 2>&1 || true
if docker image inspect "${ngencerf_image}" >/dev/null 2>&1; then
    docker create --name extract "${ngencerf_image}" >/dev/null
    sudo docker cp extract:/ngencerf/ngencerf-server/cli/dist/ngencerf /usr/local/bin/ngencerf
    docker rm extract >/dev/null
    sudo chmod +x /usr/local/bin/ngencerf
else
    echo "::notice::Image ${ngencerf_image} not found locally; skipping CLI extract"
fi

# Stream logs to stdout (session_runner watches for service readiness via port poll)
docker compose --project-name ${service_name} logs --follow

echo "::endgroup::"

sleep inf
