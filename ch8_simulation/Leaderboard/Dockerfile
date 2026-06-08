FROM nvidia/cuda:11.7.1-cudnn8-devel-ubuntu20.04

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG http_proxy

ARG MINIFORGE_VERSION=24.11.0-1

# マウント先のフォルダを環境変数指定用に保持
ARG CARLA_ROOT="/workspace/CARLA"
ARG SCENARIO_RUNNER_ROOT="/workspace/scenario_runner"
ARG LEADERBOARD_ROOT="/workspace/leaderboard"
ARG TEAM_CODE_ROOT="/workspace/team_code"

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

# Miniforgeで仮想環境構築
RUN curl -fsSL -o /tmp/Miniforge3.sh \
      https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VERSION}/Miniforge3-Linux-x86_64.sh \
    && bash /tmp/Miniforge3.sh -b -p /opt/conda \
    && rm /tmp/Miniforge3.sh \
    && /opt/conda/bin/conda clean -ya \
    && /opt/conda/bin/conda create -n python37 python=3.7 numpy networkx scipy six requests

ENV PATH "${CARLA_ROOT}/PythonAPI/carla/dist/carla-0.9.15-py3.7-linux-x86_64.egg":"/opt/conda/envs/python37/bin":"/opt/conda/envs/bin":$PATH

# Copy the files into the docker
WORKDIR /workspace

# 環境変数をARGから読取
ENV CARLA_ROOT=${CARLA_ROOT}
ENV SCENARIO_RUNNER_ROOT=${SCENARIO_RUNNER_ROOT}
ENV LEADERBOARD_ROOT=${LEADERBOARD_ROOT}
ENV TEAM_CODE_ROOT=${TEAM_CODE_ROOT}

# requirements.txtをCOPYしてインストール
COPY scenario_runner/requirements.txt ${SCENARIO_RUNNER_ROOT}/requirements.txt
COPY leaderboard/requirements.txt ${LEADERBOARD_ROOT}/requirements.txt
RUN /opt/conda/bin/conda run -n python37 pip install -r ${SCENARIO_RUNNER_ROOT}/requirements.txt
RUN /opt/conda/bin/conda run -n python37 pip install -r ${LEADERBOARD_ROOT}/requirements.txt
# lxmlはrequirements.txtに入っていないため、個別にインストール
RUN /opt/conda/bin/conda run -n python37 pip install lxml

RUN mkdir -p /workspace/results

ENV PYTHONPATH "${CARLA_ROOT}/PythonAPI/carla/dist/carla-0.9.15-py3.7-linux-x86_64.egg":"${SCENARIO_RUNNER_ROOT}":"${CARLA_ROOT}/PythonAPI/carla":"${LEADERBOARD_ROOT}":"${TEAM_CODE_ROOT}":${PYTHONPATH}

############################################################################################
####                     BEGINNING OF AGENT SPECIFIC COMMANDS                           ####
############################################################################################

ENV TEAM_AGENT ${TEAM_CODE_ROOT}/npc_agent.py
# ENV TEAM_CONFIG ${TEAM_CODE_ROOT}/YOUR_CONFIG_FILE
ENV CHALLENGE_TRACK_CODENAME SENSORS

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
    && echo "conda activate python37" >> ~/.bashrc
