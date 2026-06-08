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
#
# Python 3.8 is required (and pinned): the SLURM wrapper app uses
# subprocess.run(capture_output=...), which only exists on Python >= 3.7, while
# the system python3 is 3.6 on some cluster nodes.
SLURM_APP_VENV=${service_parent_install_dir}/ngencerf-venv
PYTHON_BIN=python3.8

if ! command -v ${PYTHON_BIN} >/dev/null 2>&1; then
    echo "::error::${PYTHON_BIN} is required for the SLURM wrapper app but was not found."
    exit 1
fi

# Rebuild the venv if it is missing gunicorn or was created with an unsupported
# Python (e.g. an older venv built with python3 == 3.6).
if [ -f "${SLURM_APP_VENV}/bin/gunicorn" ] && \
   "${SLURM_APP_VENV}/bin/python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' >/dev/null 2>&1; then
    echo "::notice::Python dependencies already installed at ${SLURM_APP_VENV}"
else
    echo "::group::Python Dependencies"
    echo "::notice::Creating virtual environment at ${SLURM_APP_VENV} using ${PYTHON_BIN}"
    rm -rf "${SLURM_APP_VENV}"
    mkdir -p ${service_parent_install_dir}
    ${PYTHON_BIN} -m venv ${SLURM_APP_VENV}
    ${SLURM_APP_VENV}/bin/pip install Flask gunicorn
    echo "::endgroup::"
fi
