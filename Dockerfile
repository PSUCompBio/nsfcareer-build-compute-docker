FROM nsfcareer/femtech:multiarch AS femtechprod

FROM ubuntu:focal

RUN apt-get update && \
  apt-get install -y  --no-install-recommends \
  wget gnupg ca-certificates

RUN wget --no-check-certificate -qO - https://www.mongodb.org/static/pgp/server-4.4.asc | apt-key add -
RUN echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu bionic/mongodb-org/4.4 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-4.4.list

RUN apt-get update && \
  apt-get install -y  --no-install-recommends \
  openmpi-bin libopenblas-base openssh-client openssl \
  libgl1 libxt6 xvfb jq curl zip unzip \
  libopengl0 ffmpeg python3-matplotlib \
  python3-numpy python3-tk python3-paraview mongodb-org-shell awscli less && rm -rf /var/lib/apt/lists/* 

# Setup home environment
RUN useradd -rm -d /home/ubuntu -s /bin/bash -g root -G sudo -u 1000 ubuntu
USER ubuntu
WORKDIR /home/ubuntu

RUN mkdir FemTechRun FemTechRun/results FemTechRun/results/vtu

COPY --from=femtechprod ["/home/ubuntu/FemTechRun/.", \
  "/home/ubuntu/FemTechRun/"]

COPY --chown=ubuntu:root ./simulation.sh .
RUN chmod +x simulation.sh

# To setup
# docker pull nsfcareer/multipleviewport:production
# docker pull nsfcareer/mergepolydata:develop
# docker pull nsfcareer/compute:test
# docker pull nsfcareer/femtech:production
# mkdir builddocker
# cp simulation.sh builddocker/
# docker build --pull --cache-from nsfcareer/mergepolydata:develop --target mergepolydata --tag nsfcareer/mergepolydata:develop -f Dockerfile builddocker
# docker build --pull --cache-from nsfcareer/mergepolydata:develop --cache-from nsfcareer/multipleviewport:production --target multiviewport --tag nsfcareer/multipleviewport:production -f Dockerfile builddocker
# docker build --pull --cache-from nsfcareer/femtech:production --cache-from nsfcareer/multipleviewport:production --cache-from nsfcareer/compute:test --cache-from nsfcareer/mergepolydata:develop --tag nsfcareer/compute:test -f Dockerfile builddocker
# docker login
# docker push nsfcareer/multipleviewport:production
# docker push nsfcareer/mergepolydata:develop
# docker push nsfcareer/compute:test
