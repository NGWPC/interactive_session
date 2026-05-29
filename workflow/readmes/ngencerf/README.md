# NGENCERF Interactive Session

Launch the **NGENCERF** (Next Generation Engine for Community Research on Environmental Flows) application stack as a browser-based interactive session on an HPC cluster.

## Features

- Full NGENCERF stack: server (Django/REST API), UI (React), and SLURM job submission API
- Runs NWM calibration, validation, forecast, hindcast, cold-start, and verification jobs on SLURM
- NGINX reverse proxy with WebSocket support, running as an unprivileged Singularity container
- SLURM wrapper Flask app for submitting ngen-cal/nwm-fcst-mgr/nwm-verf Singularity jobs
- Automatic callback retry — pending job callbacks resume when a session restarts
- Optional local Docker image build for server and UI components
- Connect-only mode to attach a new browser session to an already-running service

## Use Cases

- Running NWM calibration experiments and inspecting results in the browser
- Submitting and monitoring multi-step hydrological modeling workflows via SLURM
- Iterative forecast and hindcast runs with real-time status updates
- Collaborative analysis of NGENCERF run outputs on shared HPC storage

## Requirements

The target cluster must have:
- **Docker** (accessible to the session user, sudo required for certain operations)
- **Singularity/Apptainer** (for the NGINX proxy and NWM computation containers)
- **SLURM** with `scontrol`, `sbatch`, `squeue`, `sacct`, `scancel` available
- **Passwordless sudo** for the session user (`sudo -n true` must succeed)
- **Python 3** with `venv` module (for the SLURM wrapper app virtual environment)
- Pre-pulled Singularity containers: nginx-unprivileged, nwm-cal-mgr, nwm-fcst-mgr, nwm-verf
- Pre-cloned repositories on shared storage: ngencerf-server (with `production-pw.yaml`) and ngencerf-ui (with `compose.yaml`)
- Shared filesystem accessible from both login and compute nodes for data and software installs

## Configuration

### Compute Cluster Settings

| Field | Description |
|-------|-------------|
| Service host | The cluster resource on which to run the session |
| Schedule Job? | Submit via SLURM (`sbatch`) or run on the login/controller node |
| SLURM partition | Partition to use when scheduling (optional) |
| Walltime | Maximum wall-clock time; default `08:00:00` |
| Scheduler Directives | Extra `#SBATCH` lines for GPU, node pinning, etc. |

### NGENCERF Settings

**Container Paths** — absolute paths on the cluster filesystem:

| Field | Description |
|-------|-------------|
| NGINX Singularity Container Path | Path to `nginx-unprivileged.sif` |
| NWM Calibration Manager Container Path | Path to the nwm-cal-mgr `.sif` |
| NWM Forecast Manager Container Path | Path to the nwm-fcst-mgr `.sif` |
| NWM Verification Container Path | Path to the nwm-verf `.sif` |

**Data Directories:**

| Field | Description |
|-------|-------------|
| Data Directory (host path) | Shared filesystem path mounted into containers (e.g. `/ngencerf-app/data/`) |
| Data Directory (container path) | Bind-mount target inside containers; default `/ngencerf/data/` |

**Application Repositories:**

| Field | Description |
|-------|-------------|
| NGENCERF Server Repository Path | Path to the ngencerf-server checkout (must contain `production-pw.yaml`) |
| NGENCERF UI Repository Path | Path to the ngencerf-ui checkout (must contain `compose.yaml`) |

**Build Options:**

| Field | Description |
|-------|-------------|
| Build Server Image Locally? | Rebuild the ngencerf-server Docker image from source; default `No` |
| Build UI Image Locally? | Rebuild the ngencerf-ui Docker image from source; default `No` |

**Runtime Options:**

| Field | Description |
|-------|-------------|
| SLURM Wrapper App Workers | Gunicorn worker count for the job-submission API; default `4` |
| Connect to Existing Session? | Attach browser to an already-running service without relaunching containers |
| Python Install Directory | Location for the SLURM wrapper app virtual environment; default `${HOME}/pw/software` |

## Getting Started

1. Select the cluster resource and configure scheduler settings.
2. Fill in the paths to all required Singularity containers, the shared data directory, and the application repositories.
3. Click **Execute** to launch the session.
4. Wait for the session URL to appear — click it to open the NGENCERF application in your browser.
5. When finished, cancel the workflow job to stop all containers and free cluster resources.
