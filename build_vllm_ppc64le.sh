#!/bin/bash
set -eoux pipefail

PYTHON_VERSION=3.12
WHEEL_DIR=/wheelsdir
HOME=/root
CURDIR=$(pwd)
VENV=/opt/venv

# install development packages
rpm -ivh https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
microdnf install -y \
    git jq gcc-toolset-13 automake libtool clang-devel openssl-devel freetype-devel fribidi-devel \
    harfbuzz-devel kmod lcms2-devel libimagequant-devel libjpeg-turbo-devel llvm15 llvm15-devel \
    libraqm-devel libtiff-devel libwebp-devel libxcb-devel ninja-build openjpeg2-devel pkgconfig protobuf* \
    tcl-devel tk-devel xsimd-devel zeromq-devel zlib-devel python${PYTHON_VERSION}-devel python${PYTHON_VERSION}-pip

# install rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# setup python env
python${PYTHON_VERSION} -m venv ${VENV}

source /opt/rh/gcc-toolset-13/enable
source /root/.cargo/env
source ${VENV}/bin/activate
ln -sf /usr/lib64/libatomic.so.1 /usr/lib64/libatomic.so 
export PATH=$PATH:/usr/lib64/llvm15/bin

python -m pip install -U pip uv setuptools build wheel

export MAX_JOBS=${MAX_JOBS:-$(nproc)}

cd ${CURDIR}

# Install Numactl
# IMPORTANT: Ensure Numactl is installed in the final image
export NUMACTL_VERSION=${NUMACTL_VERSION:-$(curl -s https://api.github.com/repos/numactl/numactl/releases/latest | jq -r '.tag_name' | sed 's/v//')}
git clone --recursive https://github.com/numactl/numactl.git -b v${NUMACTL_VERSION}
cd numactl
autoreconf -i && ./configure
make -j ${MAX_JOBS:-$(nproc)} && make install

cd ${CURDIR}

# Install OpenBlas
# IMPORTANT: Ensure Openblas is installed in the final image
export OPENBLAS_VERSION=${OPENBLAS_VERSION:-$(curl -s https://api.github.com/repos/OpenMathLib/OpenBLAS/releases/latest | jq -r '.tag_name' | sed 's/v//')}
curl -L https://github.com/OpenMathLib/OpenBLAS/releases/download/v${OPENBLAS_VERSION}/OpenBLAS-${OPENBLAS_VERSION}.tar.gz | tar xz
# rename directory for mounting (without knowing version numbers) in multistage builds
mv OpenBLAS-${OPENBLAS_VERSION}/ OpenBLAS/
cd OpenBLAS/
make -j${MAX_JOBS} TARGET=POWER9 BINARY=64 USE_OPENMP=1 USE_THREAD=1 NUM_THREADS=120 DYNAMIC_ARCH=1 INTERFACE64=0
make install
cd ..

# set path for openblas
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/OpenBLAS/lib/:/usr/local/lib64:/usr/local/lib
export PKG_CONFIG_PATH=$(find / -type d -name "pkgconfig" 2>/dev/null | tr '\n' ':')

cd ${CURDIR}

export TORCH_VERSION=${TORCH_VERSION:-$(grep -E '^torch==.+==\s*\"ppc64le\"' requirements/cpu.txt | grep -Eo '\b[0-9\.]+\b')}
export _GLIBCXX_USE_CXX11_ABI=1
git clone --recursive https://github.com/pytorch/pytorch.git -b v${TORCH_VERSION}
cd pytorch
uv pip install -r requirements.txt
python setup.py develop
rm -f dist/torch*+git*whl
MAX_JOBS=${MAX_JOBS:-$(nproc)} \
PYTORCH_BUILD_VERSION=${TORCH_VERSION} PYTORCH_BUILD_NUMBER=1 uv build --wheel --out-dir ${WHEEL_DIR}

cd ${CURDIR}

export TORCHVISION_VERSION=${TORCHVISION_VERSION:-$(grep -E '^torchvision==.+==\s*\"ppc64le\"' requirements/cpu.txt | grep -Eo '\b[0-9\.]+\b')}
export TORCHVISION_USE_NVJPEG=0 TORCHVISION_USE_FFMPEG=0
git clone --recursive https://github.com/pytorch/vision.git -b v${TORCHVISION_VERSION}
cd vision
MAX_JOBS=${MAX_JOBS:-$(nproc)} \
BUILD_VERSION=${TORCHVISION_VERSION} \
uv build --wheel --out-dir ${WHEEL_DIR} --no-build-isolation

cd ${CURDIR}

export TORCHAUDIO_VERSION=${TORCHAUDIO_VERSION:-$(grep -E '^torchaudio==.+==\s*\"ppc64le\"' requirements/cpu.txt | grep -Eo '\b[0-9\.]+\b')}
export BUILD_SOX=1 BUILD_KALDI=1 BUILD_RNNT=1 USE_FFMPEG=0 USE_ROCM=0 USE_CUDA=0
export TORCHAUDIO_TEST_ALLOW_SKIP_IF_NO_FFMPEG=1
git clone --recursive https://github.com/pytorch/audio.git -b v${TORCHAUDIO_VERSION}
cd audio
MAX_JOBS=${MAX_JOBS:-$(nproc)} \
BUILD_VERSION=${TORCHAUDIO_VERSION} \
uv build --wheel --out-dir ${WHEEL_DIR} --no-build-isolation

cd ${CURDIR}

export PYARROW_VERSION=${PYARROW_VERSION:-$(curl -s https://api.github.com/repos/apache/arrow/releases/latest | jq -r '.tag_name' | grep -Eo "[0-9\.]+")}
git clone --recursive https://github.com/apache/arrow.git -b apache-arrow-${PYARROW_VERSION}
cd arrow/cpp
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DARROW_PYTHON=ON \
    -DARROW_BUILD_TESTS=OFF \
    -DARROW_JEMALLOC=ON \
    -DARROW_BUILD_STATIC="OFF" \
    -DARROW_PARQUET=ON \
    ..
make install -j ${MAX_JOBS:-$(nproc)}
cd ../../python/
uv pip install -v -r requirements-wheel-build.txt
PYARROW_PARALLEL=${PYARROW_PARALLEL:-$(nproc)} \
python setup.py build_ext \
    --build-type=release --bundle-arrow-cpp \
    bdist_wheel --dist-dir ${WHEEL_DIR}

cd ${CURDIR}

export NUMBA_VERSION=${NUMBA_VERSION:-$(grep -Eo '^numba.+;' requirements/cpu.txt | grep -Eo '\b[0-9\.]+\b' | tail -1)}
git clone --recursive https://github.com/numba/numba.git -b ${NUMBA_VERSION}
cd numba
if ! grep '#include "dynamic_annotations.h"' numba/_dispatcher.cpp; then
    sed -i '/#include "internal\/pycore_atomic.h"/i\#include "dynamic_annotations.h"' numba/_dispatcher.cpp;
fi
python -m build --wheel --installer=uv --outdir ${WHEEL_DIR}

cd ${CURDIR}

export GRPC_PYTHON_BUILD_SYSTEM_OPENSSL=1

uv pip install ${WHEEL_DIR}/*.whl
