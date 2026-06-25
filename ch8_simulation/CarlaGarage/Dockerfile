# syntax=docker/dockerfile:1

# CUDA and Ubuntu Versions
ARG CUDA_VERSION=12.1.1
ARG UBUNTU_VERSION=22.04
# Base image
FROM nvidia/cuda:${CUDA_VERSION}-cudnn8-devel-ubuntu${UBUNTU_VERSION}

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG http_proxy

ARG TORCH_CUDA=cu121
ARG MINIFORGE_VERSION=24.11.0-1

# マウント先のフォルダを環境変数指定用に保持
ARG CARLA_ROOT="/workspace/CARLA"
ARG CARLA_GARAGE_ROOT="/workspace/carla_garage"
ARG SCENARIO_RUNNER_ROOT="${CARLA_GARAGE_ROOT}/scenario_runner"
ARG LEADERBOARD_ROOT="${CARLA_GARAGE_ROOT}/leaderboard"
ARG TEAM_CODE_ROOT="${CARLA_GARAGE_ROOT}/team_code"

RUN apt-get update && apt-get install --reinstall -y locales && locale-gen en_US.UTF-8 && rm -rf /var/lib/apt/lists/*
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US
ENV LC_ALL en_US.UTF-8
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    curl \
    vim \
    ca-certificates \
    libjpeg-dev \
    libpng16-16 \
    libtiff5 \
    libpng-dev \
    python3-dev \
    python3-pip \
    python3-setuptools && \
    python3 -m pip install --upgrade pip && \
    rm -rf /var/lib/apt/lists/*

# Install dependencies for CARLA Garage
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 && \
    rm -rf /var/lib/apt/lists/*

# Copy the files into the docker
WORKDIR /workspace
COPY carla_garage/environment.yml ${CARLA_GARAGE_ROOT}/environment.yml
COPY carla_garage/team_code/requirements.txt ${CARLA_GARAGE_ROOT}/team_code/requirements.txt

# Miniforgeで仮想環境構築
RUN curl -fsSL -o /tmp/Miniforge3.sh \
      https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VERSION}/Miniforge3-Linux-x86_64.sh \
    && bash /tmp/Miniforge3.sh -b -p /opt/conda \
    && rm /tmp/Miniforge3.sh \
    && /opt/conda/bin/conda clean -ya \
    && /opt/conda/bin/conda env create -f ${CARLA_GARAGE_ROOT}/environment.yml

ENV PATH "/opt/conda/envs/garage_2/bin":"/opt/conda/envs/bin":$PATH

# Install PyTorch and torchvision again to ensure CUDA compatibility (conda env create may install CPU versions)
RUN /opt/conda/bin/conda run -n garage_2 \
    pip install torch==2.5.0 torchvision==0.20.0 torchaudio==2.5.0 \
        --index-url https://download.pytorch.org/whl/${TORCH_CUDA}

# 環境変数をARGから読取
ENV CARLA_ROOT=${CARLA_ROOT}
ENV CARLA_GARAGE_ROOT=${CARLA_GARAGE_ROOT}
ENV SCENARIO_RUNNER_ROOT=${SCENARIO_RUNNER_ROOT}
ENV LEADERBOARD_ROOT=${LEADERBOARD_ROOT}
ENV TEAM_CODE_ROOT=${TEAM_CODE_ROOT}

# データセット収集用の環境変数CHALLENGE_TRACK_CODENAMEをMAPに設定（検証用はSENSORS）
ENV DATASET_TRACK_CODENAME=MAP

RUN mkdir -p ${CARLA_GARAGE_ROOT}/results

ENV PYTHONPATH "${CARLA_ROOT}/PythonAPI/carla":"${SCENARIO_RUNNER_ROOT}":"${LEADERBOARD_ROOT}":${PYTHONPATH}

############################################################################################
####                     BEGINNING OF AGENT SPECIFIC COMMANDS                           ####
############################################################################################

# ENV TEAM_AGENT ${TEAM_CODE_ROOT}/sensor_agent.py
# ENV TEAM_CONFIG ${TEAM_CODE_ROOT}/YOUR_CONFIG_FILE
# ENV CHALLENGE_TRACK_CODENAME SENSORS

############################################################################################
####                        END OF AGENT SPECIFIC COMMANDS                              ####
############################################################################################

# non-root user作成
ARG USERNAME=developer
ARG UID=1000
ARG GID=1000
RUN groupadd -g ${GID} ${USERNAME} \
    && useradd -m -u ${UID} -g ${GID} -s /bin/bash ${USERNAME} \
    && chown -R ${UID}:${GID} /workspace
USER ${USERNAME}

# non-root userでcondaを使用できるようにする
RUN echo ". /opt/conda/etc/profile.d/conda.sh" >> ~/.bashrc \
    && echo "conda activate garage_2" >> ~/.bashrc
