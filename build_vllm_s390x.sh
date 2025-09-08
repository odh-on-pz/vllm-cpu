#!/bin/bash
set -eoux pipefail

PYTHON_VERSION=3.12
WHEEL_DIR=/wheelsdir
HOME=/root
CURDIR=$(pwd)
VIRTUAL_ENV=/opt/venv
VLLM_VERSION="v0.10.0.2"

# install development packages
rpm -ivh https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
microdnf install -y \
    which procps findutils tar vim git gcc gcc-gfortran g++ make patch zlib-devel \
    libjpeg-turbo-devel libtiff-devel libpng-devel libwebp-devel freetype-devel harfbuzz-devel \
    openssl-devel openblas openblas-devel autoconf automake libtool cmake numpy libsndfile \
    clang llvm-devel llvm-static clang-devel && \
    microdnf clean all

microdnf install -y \
    python${PYTHON_VERSION}-devel python${PYTHON_VERSION}-pip python${PYTHON_VERSION}-wheel  && \
    python${PYTHON_VERSION} -m venv $VIRTUAL_ENV && pip install --no-cache -U pip wheel uv && microdnf clean all

curl https://sh.rustup.rs -sSf | sh -s -- -y && \
    . "$CARGO_HOME/env" && \
    rustup default stable && \
    rustup show

# -------------------------
# Apache Arrow (C++ + Python)
# -------------------------

cd ${CURDIR}

git clone https://github.com/apache/arrow.git
cd arrow/cpp
mkdir -p release
cd release
cmake -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DARROW_PYTHON=ON \
      -DARROW_PARQUET=ON \
      -DARROW_ORC=ON \
      -DARROW_FILESYSTEM=ON \
      -DARROW_WITH_LZ4=ON \
      -DARROW_WITH_ZSTD=ON \
      -DARROW_WITH_SNAPPY=ON \
      -DARROW_JSON=ON \
      -DARROW_CSV=ON \
      -DARROW_DATASET=ON \
      -DPROTOBUF_PROTOC_EXECUTABLE=/usr/bin/protoc \
      -DARROW_DEPENDENCY_SOURCE=BUNDLED \
      ..
make -j"$(nproc)"
make install
cd ../../python
export PYARROW_PARALLEL=4
export ARROW_BUILD_TYPE=release
uv pip install -r requirements-build.txt
python setup.py build_ext --build-type="$ARROW_BUILD_TYPE" --bundle-arrow-cpp bdist_wheel --dist-dir "${WHEEL_DIR}"

# -------------------------
# numactl
# -------------------------
cd ${CURDIR}
curl -LO https://github.com/numactl/numactl/archive/refs/tags/v2.0.18.tar.gz
tar -xvzf v2.0.18.tar.gz
mv numactl-2.0.18/ numactl/
cd numactl
./autogen.sh
./configure
make
export C_INCLUDE_PATH="/usr/local/include:$C_INCLUDE_PATH"

# -------------------------
# PyTorch
# -------------------------
export TORCH_VERSION=2.7.0
export _GLIBCXX_USE_CXX11_ABI=1
export CARGO_HOME=/root/.cargo
export RUSTUP_HOME=/root/.rustup
export PATH="$CARGO_HOME/bin:$RUSTUP_HOME/bin:$PATH"
cd ${CURDIR}
git clone https://github.com/pytorch/pytorch.git
cd pytorch
git checkout v${TORCH_VERSION}
git submodule sync
git submodule update --init --recursive
uv pip install cmake ninja
uv pip install -r requirements.txt
python setup.py bdist_wheel --dist-dir "${WHEEL_DIR}"
uv pip install ${WHEEL_DIR}/torch-${TORCH_VERSION}*.whl

# -------------------------
# TorchVision
# -------------------------
export TORCH_VISION_VERSION=v0.20.1
cd ${CURDIR}
git clone https://github.com/pytorch/vision.git
cd vision
git checkout $TORCH_VISION_VERSION
python setup.py bdist_wheel --dist-dir "${WHEEL_DIR}"

# -------------------------
# hf-xet
# -------------------------
cd ${CURDIR}
git clone https://github.com/huggingface/xet-core.git
cd xet-core/hf_xet/
uv pip install maturin patchelf
python -m maturin build --release --out "${WHEEL_DIR}"

# -------------------------
# numba & llvmlite 
# -------------------------
export MAX_JOBS=${MAX_JOBS:-"$(nproc)"}
export NUMBA_VERSION=0.61.2
cd ${CURDIR}
microdnf install ninja-build gcc gcc-c++ -y
git clone --recursive https://github.com/llvm/llvm-project.git -b llvmorg-15.0.7
git clone --recursive https://github.com/numba/llvmlite.git -b v0.44.0
git clone --recursive https://github.com/numba/numba.git -b ${NUMBA_VERSION}
cd llvm-project
mkdir build
cd build
uv pip install 'cmake<4' setuptools numpy
export PREFIX=/usr/local
CMAKE_ARGS="${CMAKE_ARGS:-} -DLLVM_ENABLE_PROJECTS=lld;libunwind;compiler-rt"
CFLAGS="$(echo $CFLAGS | sed 's/-fno-plt //g')"
CXXFLAGS="$(echo $CXXFLAGS | sed 's/-fno-plt //g')"
CMAKE_ARGS="$CMAKE_ARGS -DFFI_INCLUDE_DIR=$PREFIX/include"
CMAKE_ARGS="$CMAKE_ARGS -DFFI_LIBRARY_DIR=$PREFIX/lib"
cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_LIBRARY_PATH="$PREFIX" \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_RTTI=ON \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_GO_TESTS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_UTILS=ON \
    -DLLVM_INSTALL_UTILS=ON \
    -DLLVM_UTILS_INSTALL_DIR=libexec/llvm \
    -DLLVM_BUILD_LLVM_DYLIB=OFF \
    -DLLVM_LINK_LLVM_DYLIB=OFF \
    -DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=WebAssembly \
    -DLLVM_ENABLE_FFI=ON \
    -DLLVM_ENABLE_Z3_SOLVER=OFF \
    -DLLVM_OPTIMIZED_TABLEGEN=ON \
    -DCMAKE_POLICY_DEFAULT_CMP0111=NEW \
    -DCOMPILER_RT_BUILD_BUILTINS=ON \
    -DCOMPILER_RT_BUILTINS_HIDE_SYMBOLS=OFF \
    -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
    -DCOMPILER_RT_BUILD_CRT=OFF \
    -DCOMPILER_RT_BUILD_MEMPROF=OFF \
    -DCOMPILER_RT_BUILD_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
    -DCOMPILER_RT_BUILD_XRAY=OFF \
    -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
    -DCOMPILER_RT_BUILD_ORC=OFF \
    -DCOMPILER_RT_INCLUDE_TESTS=OFF \
    ${CMAKE_ARGS} -GNinja ../llvm
ninja install
cd ../../llvmlite
python setup.py bdist_wheel --dist-dir "${WHEEL_DIR}"
cd ../numba
if ! grep '#include \"dynamic_annotations.h\"' numba/_dispatcher.cpp; then
   sed -i '/#include \"internal\\/pycore_atomic.h\"/i\\#include \"dynamic_annotations.h\"' numba/_dispatcher.cpp
fi
python setup.py bdist_wheel --dist-dir "${WHEEL_DIR}"

# -------------------------
# aws-lc-sys patch (s390x)
# -------------------------
cd ${CURDIR}
export AWS_LC_VERSION=v0.30.0
git clone --recursive https://github.com/aws/aws-lc-rs.git
cd aws-lc-rs
git checkout tags/aws-lc-sys/${AWS_LC_VERSION}
git submodule sync
git submodule update --init --recursive
cd aws-lc-sys
sed -i '682 s/strncmp(buf, \"-----END \", 9)/memcmp(buf, \"-----END \", 9)/' aws-lc/crypto/pem/pem_lib.c
sed -i '712 s/strncmp(buf, \"-----END \", 9)/memcmp(buf, \"-----END \", 9)/' aws-lc/crypto/pem/pem_lib.c
sed -i '747 s/strncmp(buf, \"-----END \", 9)/memcmp(buf, \"-----END \", 9)/' aws-lc/crypto/pem/pem_lib.c

# -------------------------
# outlines-core (patched to local aws-lc-sys)
# -------------------------
cd ${CURDIR}
export OUTLINES_CORE_VERSION=0.2.10
git clone https://github.com/dottxt-ai/outlines-core.git
cd outlines-core
git checkout tags/${OUTLINES_CORE_VERSION}
sed -i \"s/version = \\\"0.0.0\\\"/version = \\\"${OUTLINES_CORE_VERSION}\\\"/\" Cargo.toml
echo '[patch.crates-io]' >> Cargo.toml
echo 'aws-lc-sys = { path = \"${CURDIR}/aws-lc-sys\" }' >> Cargo.toml
uv pip install maturin
python -m maturin build --release --out "${WHEEL_DIR}"

# -------------------------
# install all wheels we've built so far
# -------------------------
cd ${CURDIR}

mkdir -p lapack
mkdir -p OpenBLAS
uv pip install ${WHEEL_DIR}/*.whl

export GRPC_PYTHON_BUILD_SYSTEM_OPENSSL=1

# -------------------------
# Install remaining python deps
# -------------------------
# Install dependencies, including PyTorch and Apache Arrow
cd ${CURDIR}
sed -i '/^torch/d' requirements/build.txt

uv pip install -v \
    -r requirements/build.txt \
    -r requirements/cpu.txt


# -------------------------
# vllm build
# -------------------------
SETUPTOOLS_SCM_PRETEND_VERSION="${VLLM_VERSION}" \
VLLM_TARGET_DEVICE=cpu python setup.py bdist_wheel --dist-dir "${WHEEL_DIR}"
