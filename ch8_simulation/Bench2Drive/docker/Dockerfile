# syntax=docker/dockerfile:1

############################
# Set the base image with CUDA and cuDNN
############################
# CUDA and Ubuntu Versions
ARG CUDA_VERSION=11.8.0
ARG UBUNTU_VERSION=22.04

# Base image
FROM nvidia/cuda:${CUDA_VERSION}-cudnn8-devel-ubuntu${UBUNTU_VERSION}

############################
# Install Python, Conda(Miniforge), PyTorch, OpenMMLab, and other dependencies
############################
# Python version
ARG PYTHON_VERSION=3.8
ARG TORCH_CUDA=cu118
# Miniforge settings
ARG MINIFORGE_VERSION=24.11.0-1
ARG CONDA_DIR=/opt/conda
# GPU architecture for mmcv build
ARG TORCH_CUDA_ARCH_LIST=8.9
# CARLA_ROOT
ARG CARLA_ROOT=/workspace/carla

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1
# Install OS packages (GCC9.4 is recommended)
# (libsm6, libxext6, and libxrender1 are for OpenCV imshow)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc-9 g++-9 \
    git curl wget ca-certificates \
    ffmpeg \
    libgl1 libglib2.0-0 \
    libsm6 libxext6 libxrender1 \
    && rm -rf /var/lib/apt/lists/*
# Install Miniforge
RUN curl -fsSL -o /tmp/Miniforge3.sh \
      https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VERSION}/Miniforge3-Linux-x86_64.sh \
    && bash /tmp/Miniforge3.sh -b -p ${CONDA_DIR} \
    && rm /tmp/Miniforge3.sh
ENV PATH=${CONDA_DIR}/bin:${PATH}

# STEP 1: Create a conda virtual environment.
RUN conda create -n b2d_zoo python=${PYTHON_VERSION} -y
# STEP 2: Install cudatoolkit -> skipped (Already installed)
# STEP 3: Install PyTorch and torchvision
RUN conda run -n b2d_zoo \
        pip install torch==2.0.1 torchvision==0.15.2 torchaudio==2.0.2 \
            --index-url https://download.pytorch.org/whl/${TORCH_CUDA}
# STEP 4: Set environment variables
ENV CC=/usr/bin/gcc-9 \
    CXX=/usr/bin/g++-9 \
    CUDA_HOME=/usr/local/cuda \
    CPATH=/usr/local/cuda/include \
    PATH=/usr/local/cuda/bin:${PATH} \
    LD_LIBRARY_PATH=/opt/conda/envs/b2d_zoo/lib:/usr/local/cuda/lib64:${LD_LIBRARY_PATH}
# STEP 5: Install ninja and packaging (ninja is already installed by apt)
RUN conda run -n b2d_zoo \
    pip install ninja packaging

# mmcv build settings
ENV TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST} \
    FORCE_CUDA=1 \
    MMCV_WITH_OPS=1
# STEP 6: Install our repo
WORKDIR /workspace/Bench2DriveZoo
COPY ./Bench2DriveZoo /workspace/Bench2DriveZoo/
RUN conda run -n b2d_zoo \
    pip install -v -e .

# Install other Python libraries
WORKDIR /workspace
COPY requirements.txt /workspace/requirements.txt
RUN conda run -n b2d_zoo \
    pip install -r requirements.txt
# Avoid Pillow error (AttributeError: module 'numpy.typing' has no attribute 'NDArray')
RUN conda run -n b2d_zoo pip install -U Pillow==9.5.0

# Copy Bench2Drive folder and add symbolic links
COPY ./Bench2Drive /workspace/Bench2Drive/
RUN mkdir -p /workspace/Bench2Drive/leaderboard \
    && rm -rf /workspace/Bench2Drive/leaderboard/team_code \
    && ln -s /workspace/Bench2DriveZoo/team_code /workspace/Bench2Drive/leaderboard/team_code \
    && ln -s /workspace/Bench2DriveZoo /workspace/Bench2Drive/

# Carla settings
ENV CARLA_ROOT=${CARLA_ROOT}
RUN echo "${CARLA_ROOT}/PythonAPI/carla/dist/carla-0.9.15-py3.7-linux-x86_64.egg" >> ${CONDA_DIR}/envs/b2d_zoo/lib/python3.8/site-packages/carla.pth

############################
# Create non-root user
############################
ARG USERNAME=developer
ARG UID=1000
ARG GID=1000
RUN groupadd -g ${GID} ${USERNAME} \
    && useradd -m -u ${UID} -g ${GID} -s /bin/bash ${USERNAME} \
    && chown -R ${UID}:${GID} /workspace
USER ${USERNAME}

# Enable conda commands for non-root user
RUN echo ". ${CONDA_DIR}/etc/profile.d/conda.sh" >> ~/.bashrc \
    && echo "conda activate b2d_zoo" >> ~/.bashrc
