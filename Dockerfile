FROM ubuntu:18.04 AS mergepolydata

RUN apt-get update && \
  apt-get install -y  --no-install-recommends curl python3-dev libpng-dev\
  cmake git g++ ca-certificates vim make libgl1-mesa-dev libxt-dev \
  zlib1g-dev xvfb sudo && rm -rf /var/lib/apt/lists/*

# Install CMake, direct binary
RUN curl -s "https://cmake.org/files/v3.17/cmake-3.17.0-Linux-x86_64.tar.gz" | tar --strip-components=1 -xz -C /usr/local

# Setup home environment
RUN useradd -rm -d /home/ubuntu -s /bin/bash -g root -G sudo -u 1000 ubuntu
USER ubuntu
WORKDIR /home/ubuntu

# Setup VTK
RUN git clone -b 'v7.1.1' --single-branch https://github.com/Kitware/VTK.git
RUN mkdir VTK/build;cd VTK/build;cmake .. -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release;make -j 16

# Setup pvpython
RUN git clone --recursive https://gitlab.kitware.com/paraview/paraview-superbuild.git
RUN cd paraview-superbuild;git fetch origin;git checkout v5.8.0;git submodule update 
RUN mkdir paraviewSuperbuildBuild;cd paraviewSuperbuildBuild;cmake -DENABLE_python=ON -DBUILD_SHARED_LIBS_paraview=OFF -DBUILD_TESTING=OFF -DENABLE_nlohmannjson=OFF -DENABLE_python3=ON -DENABLE_png=ON -DUSE_SYSTEM_python3=ON -DUSE_SYSTEM_zlib=ON -DUSE_SYSTEM_png=ON -DCMAKE_BUILD_TYPE=Release ../paraview-superbuild ;make -j 16 

# Setup MergePolyData
ADD https://api.github.com/repos/PSUCompBio/MergePolyData/git/refs/heads/develop version.json
RUN git clone -b develop --single-branch https://github.com/PSUCompBio/MergePolyData.git
RUN mkdir MergePolyData/build;cd MergePolyData/build;cmake .. -DVTK_DIR=/home/ubuntu/VTK/build;make -j 16

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
  "/home/ubuntu/MergePolyData/build/examples/multipleViewPorts/test_output.json", \
  "/home/ubuntu/MergePolyData/build/examples/multipleViewPorts/Br_color3.jpg", \
  "/home/ubuntu/MergePolyData/build/MultipleViewPorts", \
  "/home/ubuntu/MultiViewPortRun/"]

RUN mkdir Paraview

COPY --from=mergepolydata ["/home/ubuntu/paraviewSuperbuildBuild/install/bin/pvpython", \
  "/home/ubuntu/paraviewSuperbuildBuild/install/lib/python3.6", \
  "/home/ubuntu/Paraview/"]


FROM nsfcareer/femtech:production AS femtechprod

FROM ubuntu:18.04

RUN apt-get update && \
  apt-get install -y  --no-install-recommends \
  wget gnupg ca-certificates

RUN wget --no-check-certificate -qO - https://www.mongodb.org/static/pgp/server-4.4.asc | apt-key add -
RUN echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu bionic/mongodb-org/4.4 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-4.4.list

RUN apt-get update && \
  apt-get install -y  --no-install-recommends \
  openmpi-bin libopenblas-base openssh-client openssl \
  libgl1 libxt6 xvfb jq curl zip unzip \
  libopengl0 libpython3.6 ffmpeg python3-matplotlib \
  python3-numpy python3-tk mongodb-org-shell less && rm -rf /var/lib/apt/lists/* 

RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
RUN unzip awscliv2.zip
RUN ./aws/install

# Setup home environment
RUN useradd -rm -d /home/ubuntu -s /bin/bash -g root -G sudo -u 1000 ubuntu
USER ubuntu
WORKDIR /home/ubuntu

RUN mkdir FemTechRun FemTechRun/results FemTechRun/results/vtu lib

COPY --from=femtechprod ["/home/ubuntu/FemTechRun/ex5", \
  "/home/ubuntu/FemTechRun/materials.dat", \
  "/home/ubuntu/FemTechRun/simulationMovie.py", \
  "/home/ubuntu/FemTechRun/addGraph.py", \
  "/home/ubuntu/FemTechRun/mps95Movie.py", \
  "/home/ubuntu/FemTechRun/updateOutputJson.py", \
  "/home/ubuntu/FemTechRun/fine_cellcentres.txt", \
  "/home/ubuntu/FemTechRun/coarse_cellcentres.txt", \
  "/home/ubuntu/FemTechRun/ex21", \
  "/home/ubuntu/FemTechRun/materialsPressure.dat", \
  "/home/ubuntu/FemTechRun/"]

COPY --from=multiviewport ["/home/ubuntu/Paraview/pvpython", \
  "/home/ubuntu/FemTechRun/"]

COPY --from=multiviewport ["/home/ubuntu/Paraview/site-packages", \
  "/home/ubuntu/lib/"]

ENV PYTHONPATH /home/ubuntu/lib/_paraview.zip:/home/ubuntu/lib:/home/ubuntu/lib/_vtk.zip

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
