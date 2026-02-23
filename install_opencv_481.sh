#!/bin/bash
# =============================================================================
# OpenCV 4.8.1 with CUDA support for Jetson Nano (Tegra X1)
# Ubuntu 22.04 | L4T R32 | CUDA 10.2 | cuDNN 8.2 | GCC 8
#
# Build directory is on the USB stick to avoid SD card wear.
# USB stick must be mounted at /home/jetson/nano-usb before running.
# An 8GB swapfile on the USB stick is also expected to be active.
#
# Usage: bash install_opencv_481_jetson_nano.sh
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
OPENCV_VERSION="4.8.1"
USB_MOUNT="/home/jetson/nano-usb"
BUILD_DIR="${USB_MOUNT}/opencv-build"
INSTALL_PREFIX="/usr"

# Jetson Nano (Tegra X1) CUDA compute capability
ARCH="5.3"
PTX="sm_53"

# Use 4 parallel jobs only if swap is large enough (> 6 GB)
FREE_SWAP="$(free -m | awk '/^Swap/ {print $2}')"
if [[ "$FREE_SWAP" -gt "6000" ]]; then
    NO_JOB=4
else
    echo "WARNING: Swap space is ${FREE_SWAP} MB, which is less than 6 GB."
    echo "         Falling back to single-core build. This will take much longer."
    echo "         Consider activating your 8GB swapfile on the USB stick first."
    NO_JOB=1
fi

# -----------------------------------------------------------------------------
# Sanity checks
# -----------------------------------------------------------------------------
if [ ! -d "$USB_MOUNT" ]; then
    echo "ERROR: USB mount point $USB_MOUNT does not exist."
    echo "       Make sure your USB stick is mounted before running this script."
    exit 1
fi

if ! mountpoint -q "$USB_MOUNT"; then
    echo "ERROR: $USB_MOUNT is not a mounted filesystem."
    echo "       Make sure your USB stick is mounted before running this script."
    exit 1
fi

echo ""
echo "=============================================="
echo " Installing OpenCV ${OPENCV_VERSION} with CUDA"
echo " Build dir : ${BUILD_DIR}"
echo " Install   : ${INSTALL_PREFIX}"
echo " CUDA arch : ${ARCH} / ${PTX}"
echo " GCC       : $(gcc-8 --version | head -1)"
echo " Swap      : ${FREE_SWAP} MB  ->  make -j${NO_JOB}"
echo "=============================================="
echo ""
echo "Estimated build time: ~2 hours (4 cores) or ~6+ hours (1 core)"
echo ""
read -rp "Press Enter to continue, or Ctrl+C to abort..."

# -----------------------------------------------------------------------------
# Expose CUDA libs to the dynamic linker (safe: checks for duplicates)
# -----------------------------------------------------------------------------
grep -qxF '/usr/local/cuda/lib64' /etc/ld.so.conf.d/nvidia-tegra.conf || \
    sudo sh -c "echo '/usr/local/cuda/lib64' >> /etc/ld.so.conf.d/nvidia-tegra.conf"
sudo ldconfig

# -----------------------------------------------------------------------------
# Install dependencies
# -----------------------------------------------------------------------------
echo ">>> Installing dependencies..."
sudo apt-get update
sudo apt-get install -y \
    build-essential git unzip pkg-config zlib1g-dev \
    cmake \
    gcc-8 g++-8 \
    python3-dev python3-numpy python3-pip \
    gstreamer1.0-tools \
    libgstreamer-plugins-base1.0-dev \
    libgstreamer-plugins-good1.0-dev \
    libtbb2 libgtk-3-dev libxine2-dev \
    libswresample-dev libdc1394-dev \
    libjpeg-dev libjpeg8-dev libjpeg-turbo8-dev \
    libpng-dev libtiff-dev libglew-dev \
    libavcodec-dev libavformat-dev libswscale-dev \
    libgtk2.0-dev libcanberra-gtk3-module \
    libxvidcore-dev libx264-dev \
    libtbb-dev \
    libv4l-dev v4l-utils \
    libtesseract-dev libpostproc-dev \
    libvorbis-dev \
    libfaac-dev libmp3lame-dev libtheora-dev \
    libopencore-amrnb-dev libopencore-amrwb-dev \
    libopenblas-dev libatlas-base-dev libblas-dev \
    liblapack-dev liblapacke-dev libeigen3-dev gfortran \
    libhdf5-dev libprotobuf-dev protobuf-compiler \
    libgoogle-glog-dev libgflags-dev

# -----------------------------------------------------------------------------
# Download sources — skipped if already present on USB stick
# -----------------------------------------------------------------------------
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [ -d "${BUILD_DIR}/opencv" ] && [ -d "${BUILD_DIR}/opencv_contrib" ]; then
    echo ">>> Sources already present at ${BUILD_DIR}, skipping download."
else
    echo ">>> Downloading OpenCV ${OPENCV_VERSION} sources..."
    rm -rf opencv opencv_contrib opencv.zip opencv_contrib.zip

    wget -O opencv.zip "https://github.com/opencv/opencv/archive/${OPENCV_VERSION}.zip"
    wget -O opencv_contrib.zip "https://github.com/opencv/opencv_contrib/archive/${OPENCV_VERSION}.zip"

    unzip opencv.zip
    unzip opencv_contrib.zip

    mv "opencv-${OPENCV_VERSION}" opencv
    mv "opencv_contrib-${OPENCV_VERSION}" opencv_contrib

    rm opencv.zip opencv_contrib.zip
fi

# -----------------------------------------------------------------------------
# CMake configure
# Always wipe the build directory first to avoid stale cache issues
# -----------------------------------------------------------------------------
echo ">>> Wiping build directory for a clean CMake cache..."
rm -rf "${BUILD_DIR}/opencv/build"
mkdir -p "${BUILD_DIR}/opencv/build"
cd "${BUILD_DIR}/opencv/build"

echo ">>> Running CMake..."
cmake \
    -D CMAKE_BUILD_TYPE=RELEASE \
    -D CMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
    -D CMAKE_C_COMPILER=gcc-8 \
    -D CMAKE_CXX_COMPILER=g++-8 \
    -D OPENCV_EXTRA_MODULES_PATH="${BUILD_DIR}/opencv_contrib/modules" \
    -D EIGEN_INCLUDE_PATH=/usr/include/eigen3 \
    -D WITH_OPENCL=OFF \
    -D CUDA_cufft_LIBRARY=/usr/local/cuda-10.2/targets/aarch64-linux/lib/libcufft.so \
    -D CUDA_INCLUDE_DIRS=/usr/local/cuda-10.2/targets/aarch64-linux/include \
    -D CUDA_ARCH_BIN=${ARCH} \
    -D CUDA_ARCH_PTX=${PTX} \
    -D WITH_CUDA=ON \
    -D WITH_CUDNN=ON \
    -D WITH_CUBLAS=ON \
    -D ENABLE_FAST_MATH=ON \
    -D CUDA_FAST_MATH=ON \
    -D OPENCV_DNN_CUDA=ON \
    -D ENABLE_NEON=ON \
    -D WITH_QT=OFF \
    -D WITH_OPENMP=ON \
    -D BUILD_TIFF=ON \
    -D WITH_FFMPEG=ON \
    -D WITH_GSTREAMER=ON \
    -D WITH_TBB=ON \
    -D BUILD_TBB=OFF \
    -D BUILD_TESTS=OFF \
    -D WITH_EIGEN=ON \
    -D WITH_V4L=ON \
    -D WITH_LIBV4L=ON \
    -D WITH_PROTOBUF=ON \
    -D OPENCV_ENABLE_NONFREE=ON \
    -D INSTALL_C_EXAMPLES=OFF \
    -D INSTALL_PYTHON_EXAMPLES=OFF \
    -D PYTHON3_PACKAGES_PATH=/usr/lib/python3/dist-packages \
    -D OPENCV_GENERATE_PKGCONFIG=ON \
    -D BUILD_EXAMPLES=OFF \
    -D CMAKE_CXX_FLAGS="-march=native -mtune=native" \
    -D CMAKE_C_FLAGS="-march=native -mtune=native" \
    ..

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------
echo ">>> Building with -j${NO_JOB} (this will take a while)..."
make -j${NO_JOB}

# -----------------------------------------------------------------------------
# Install
# -----------------------------------------------------------------------------
echo ">>> Installing OpenCV..."

# Remove old headers to avoid conflicts
if [ -d "/usr/include/opencv4/opencv2" ]; then
    sudo rm -rf /usr/include/opencv4/opencv2
fi

sudo make install
sudo ldconfig

# -----------------------------------------------------------------------------
# Clean up build objects (~8-12 GB) — sources are kept for potential rebuild
# -----------------------------------------------------------------------------
echo ">>> Cleaning build objects to free disk space..."
rm -rf "${BUILD_DIR}/opencv/build"

echo ""
echo "=============================================="
echo " Sources kept at : ${BUILD_DIR}/opencv"
echo "                   ${BUILD_DIR}/opencv_contrib"
echo " Delete them manually once satisfied:"
echo "   rm -rf ${BUILD_DIR}"
echo "=============================================="

# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------
echo ""
echo "=============================================="
echo " Verifying installation..."
echo "=============================================="
python3 -c "
import cv2
build_info = cv2.getBuildInformation()
print(f'OpenCV version : {cv2.__version__}')

cuda_line = [l for l in build_info.splitlines() if 'CUDA' in l and 'Enabled' in l]
cudnn_line = [l for l in build_info.splitlines() if 'cuDNN' in l]
for l in cuda_line + cudnn_line:
    print(l.strip())
"

echo ""
echo "=============================================="
echo " Done! OpenCV ${OPENCV_VERSION} with CUDA installed at path /usr/include/opencv4/opencv2."
echo "=============================================="
