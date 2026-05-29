set -o pipefail

################################################################################
# Interactive Session Controller - NGENCERF
#
# Purpose: Install Python dependencies for the SLURM wrapper app
# Runs on: Controller node (has internet access)
#
# Required Environment Variables (from inputs.sh):
#   - service_parent_install_dir: Install directory (default: ${HOME}/pw/software)
################################################################################

if ! [ -z ${PW_PARENT_JOB_DIR} ]; then
    cd ${PW_PARENT_JOB_DIR}
fi

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

# Install Flask and gunicorn for the SLURM wrapper Flask app into an isolated venv.
# The venv lives on the shared filesystem so the compute node can access it.
SLURM_APP_VENV=${service_parent_install_dir}/ngencerf-venv

if ! [ -f "${SLURM_APP_VENV}/bin/gunicorn" ]; then
    echo "::group::Python Dependencies"
    echo "::notice::Creating virtual environment at ${SLURM_APP_VENV}"
    mkdir -p ${service_parent_install_dir}
    python3 -m venv ${SLURM_APP_VENV}
    ${SLURM_APP_VENV}/bin/pip install Flask gunicorn
    echo "::endgroup::"
else
    echo "::notice::Python dependencies already installed at ${SLURM_APP_VENV}"
fi
