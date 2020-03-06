FROM ubuntu:18.04 AS mergepolydata

RUN apt-get update && \
  apt-get install -y  --no-install-recommends \
  cmake git g++ ca-certificates vim make libgl1-mesa-dev libxt-dev xvfb && \
  rm -rf /var/lib/apt/lists/*

# Setup home environment
RUN useradd -rm -d /home/ubuntu -s /bin/bash -g root -G sudo -u 1000 ubuntu
USER ubuntu
WORKDIR /home/ubuntu

# Setup VTK
RUN git clone -b 'v7.1.1' --single-branch https://github.com/Kitware/VTK.git
RUN mkdir VTK/build;cd VTK/build;cmake ../ -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release;make -j 8; cd ../..

# Setup MergePolyData
ADD https://api.github.com/repos/PSUCompBio/MergePolyData/git/refs/heads/develop version.json
RUN git clone  -b develop --single-branch https://github.com/PSUCompBio/MergePolyData.git
RUN mkdir MergePolyData/build;cd MergePolyData/build;cmake .. -DVTK_DIR=/home/ubuntu/VTK/build;make -j 8

FROM ubuntu:18.04 AS multiviewport

RUN apt-get update && \
  apt-get install -y  --no-install-recommends \
  libgl1 libxt6 xvfb\
  && rm -rf /var/lib/apt/lists/*

# Setup home environment
RUN useradd -rm -d /home/ubuntu -s /bin/bash -g root -G sudo -u 1000 ubuntu
USER ubuntu
WORKDIR /home/ubuntu

# Setup FemTech
RUN mkdir MultiViewPortRun

COPY --from=mergepolydata ["/home/ubuntu/MergePolyData/build/examples/multipleViewPorts/brain3.ply", \
  "/home/ubuntu/MergePolyData/build/examples/multipleViewPorts/output.json", \
  "/home/ubuntu/MergePolyData/build/examples/multipleViewPorts/Br_color3.jpg", \
  "/home/ubuntu/MergePolyData/build/MultipleViewPorts", \
  "/home/ubuntu/MultiViewPortRun/"]

FROM nsfcareer/femtech:production AS femtechprod

FROM ubuntu:18.04

RUN apt-get update && \
  apt-get install -y  --no-install-recommends \
  openmpi-bin libopenblas-base openssh-client \
  libgl1 libxt6 xvfb jq \
  && rm -rf /var/lib/apt/lists/*

# Setup home environment
RUN useradd -rm -d /home/ubuntu -s /bin/bash -g root -G sudo -u 1000 ubuntu
USER ubuntu
WORKDIR /home/ubuntu

RUN mkdir FemTechRun FemTechRun/results FemTechRun/results/vtu

COPY --from=femtechprod ["/home/ubuntu/FemTechRun/ex5", \
  "/home/ubuntu/FemTechRun/materials.dat", \
  "/home/ubuntu/FemTechRun/coarse_brain.inp", \
  "/home/ubuntu/FemTechRun/"]

COPY --from=multiviewport ["/home/ubuntu/MultiViewPortRun/brain3.ply", \
  "/home/ubuntu/MultiViewPortRun/Br_color3.jpg", \
  "/home/ubuntu/MultiViewPortRun/MultipleViewPorts", \
  "/home/ubuntu/FemTechRun/"]

COPY --chown=ubuntu:root ./simulation.sh .
RUN chmod +x simulation.sh

# To setup
# docker pull nsfcareer/multipleviewport:production
# docker pull nsfcareer/mergepolydata:develop
# docker pull nsfcareer/compute:production
# docker pull nsfcareer/femtech:production
# mkdir builddocker
# cp simulation.sh builddocker/
# docker build --pull --cache-from nsfcareer/mergepolydata:develop --target mergepolydata --tag nsfcareer/mergepolydata:develop -f Dockerfile builddocker
# docker build --pull --cache-from nsfcareer/mergepolydata:develop --cache-from nsfcareer/multipleviewport:production --target multiviewport --tag nsfcareer/multipleviewport:production -f Dockerfile builddocker
# docker build --pull --cache-from nsfcareer/femtech:production --cache-from nsfcareer/multipleviewport:production --cache-from nsfcareer/compute:production --cache-from nsfcareer/mergepolydata:develop --tag nsfcareer/compute:production -f Dockerfile builddocker
# docker login
# docker push nsfcareer/multipleviewport:production
# docker push nsfcareer/mergepolydata:develop
# docker push nsfcareer/compute:production
