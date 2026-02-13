#!/usr/bin/env bash
set -euo pipefail

# JetPack 4.6.6 (Jetson Nano) quick health checks:
# - L4T / driver presence
# - CUDA (nvcc + optional sample run or minimal compile)
# - cuDNN (dpkg + dlopen check)
# - TensorRT (trtexec + python import + dlopen check)
# - VPI (package + optional sample binary)
# - OpenCV (python import)
# - VisionWorks (package presence)
# - Multimedia API / GStreamer (gst-inspect key elements)
# - Container runtime (docker + nvidia runtime presence)
# - Optional: DeepStream / Triton (if installed)

SCRIPT_NAME="$(basename "$0")"
LOG_DIR="/var/log/jetpack-selftest"
TS="$(date +"%Y%m%d-%H%M%S")"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME%.sh}-${TS}.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

PASS_CNT=0
FAIL_CNT=0
WARN_CNT=0

# --- pretty output ---
GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

ok()   { echo "${GREEN}✅ PASS${RESET}  $*"; PASS_CNT=$((PASS_CNT+1)); }
fail() { echo "${RED}❌ FAIL${RESET}  $*"; FAIL_CNT=$((FAIL_CNT+1)); }
warn() { echo "${YELLOW}⚠️  WARN${RESET}  $*"; WARN_CNT=$((WARN_CNT+1)); }

have() { command -v "$1" >/dev/null 2>&1; }

run_cmd() {
  local desc="$1"; shift
  echo "${BOLD}==>${RESET} ${desc}"
  if "$@"; then
    return 0
  else
    return 1
  fi
}

# dlopen check for a shared library via python (more robust than just "ls"):
py_dlopen() {
  local lib="$1"
  python3 - <<PY
import ctypes, sys
try:
    ctypes.CDLL("$lib")
    print("dlopen OK:", "$lib")
    sys.exit(0)
except Exception as e:
    print("dlopen FAIL:", "$lib", "->", e)
    sys.exit(1)
PY
}

section() {
  echo
  echo "${BOLD}### $* ###${RESET}"
}

################# SECTION L4T ##############################################

section "System / L4T"
if [[ -f /etc/nv_tegra_release ]]; then
  run_cmd "Show /etc/nv_tegra_release" cat /etc/nv_tegra_release && ok "L4T release file present"
else
  fail "/etc/nv_tegra_release missing (Jetson Linux / L4T not detected)"
fi

if have uname; then
  run_cmd "Kernel version" uname -a || true
fi

if have dpkg; then
  # helpful: see key NVIDIA packages exist (not a hard fail if names differ)
  dpkg -l | grep -E "nvidia-l4t-core|nvidia-l4t-kernel|nvidia-l4t-bootloader" >/dev/null 2>&1 \
    && ok "Core NVIDIA L4T packages found (dpkg)" \
    || warn "Could not confirm L4T core packages via dpkg (package naming may differ)"
fi

############# SECTION CUDA ########################################

section "CUDA (Toolkit / compiler / runtime)"

CUDA_HOME="/usr/local/cuda"
CUDA_VER_FILE="${CUDA_HOME}/version.txt"
NVCC_BIN="${CUDA_HOME}/bin/nvcc"

NVCC_OK=0

# 1) Detect CUDA toolkit on disk (independent of PATH)
if [[ -f "$CUDA_VER_FILE" ]]; then
  ok "CUDA toolkit detected on disk: $CUDA_VER_FILE"
  echo "${BOLD}==>${RESET} Contents of $CUDA_VER_FILE"
  cat "$CUDA_VER_FILE" || true
else
  fail "CUDA toolkit missing: $CUDA_VER_FILE not found"
  NVCC_OK=0
fi

# 2) If toolkit exists, use absolute nvcc path for testing (works under sudo too)
if [[ -f "$CUDA_VER_FILE" ]]; then
  if [[ -x "$NVCC_BIN" ]]; then
    if run_cmd "nvcc --version (absolute path)" "$NVCC_BIN" --version; then
      ok "nvcc usable via $NVCC_BIN"
      NVCC_OK=1
    else
      fail "nvcc exists but failed to execute: $NVCC_BIN"
      NVCC_OK=0
    fi
  else
    fail "nvcc missing or not executable at: $NVCC_BIN"
    NVCC_OK=0
  fi
fi

# 3) Minimal CUDA compile+run (only if nvcc works)
if [[ "$NVCC_OK" -eq 1 ]]; then
  CUDA_TMP="$(mktemp -d)"
  cat > "${CUDA_TMP}/cuda_smoke.cu" <<'CU'
#include <cstdio>
#include <cuda_runtime.h>
int main() {
  int n=0;
  cudaError_t e = cudaGetDeviceCount(&n);
  if (e != cudaSuccess) { printf("cudaGetDeviceCount error: %s\n", cudaGetErrorString(e)); return 2; }
  printf("CUDA devices: %d\n", n);
  if (n < 1) return 3;
  cudaDeviceProp p{};
  cudaGetDeviceProperties(&p, 0);
  printf("Device0: %s, cc %d.%d\n", p.name, p.major, p.minor);
  return 0;
}
CU

  if run_cmd "Compile minimal CUDA program" "$NVCC_BIN" -O2 "${CUDA_TMP}/cuda_smoke.cu" -o "${CUDA_TMP}/cuda_smoke"; then
    if run_cmd "Run minimal CUDA program" "${CUDA_TMP}/cuda_smoke"; then
      ok "CUDA runtime OK (compile + device query)"
    else
      fail "CUDA runtime program failed to run (driver/runtime broken?)"
    fi
  else
    fail "CUDA compilation failed (toolchain broken?)"
  fi

  rm -rf "$CUDA_TMP"

  # Note (non-invasive): PATH/LD_LIBRARY_PATH convenience for interactive use
  echo
  echo "${BOLD}Note:${RESET} CUDA works even if you run this script with sudo because it uses ${NVCC_BIN}."
  echo "If you want 'nvcc' to work interactively without typing the full path, add this globally:"
  echo "sudo tee /etc/profile.d/cuda.sh >/dev/null <<'EOF'"
  echo "export PATH=/usr/local/cuda/bin\${PATH:+:\${PATH}}"
  echo "export LD_LIBRARY_PATH=/usr/local/cuda/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
  echo "EOF"
  echo "source /etc/profile.d/cuda.sh   # or reboot / re-login"
  echo
else
  warn "Skipping CUDA compile/run tests because nvcc is not usable"
fi

# 4) Optional: build+run CUDA sample deviceQuery (if sources are present)
DEVICEQUERY_BIN=""
DEVICEQUERY_DIR=""

# Prefer a prebuilt binary if it exists somewhere
for p in \
  /usr/local/cuda/samples/1_Utilities/deviceQuery/deviceQuery \
  /usr/local/cuda-*/samples/1_Utilities/deviceQuery/deviceQuery \
  /usr/bin/deviceQuery \
  /usr/local/cuda/bin/deviceQuery
do
  [[ -x "$p" ]] && DEVICEQUERY_BIN="$p" && break
done

# If no binary, look for the sample source directory (like in your case)
if [[ -z "$DEVICEQUERY_BIN" ]]; then
  for d in \
    /usr/local/cuda/samples/1_Utilities/deviceQuery \
    /usr/local/cuda-*/samples/1_Utilities/deviceQuery
  do
    if [[ -d "$d" && -f "$d/Makefile" && -f "$d/deviceQuery.cpp" ]]; then
      DEVICEQUERY_DIR="$d"
      break
    fi
  done
fi

if [[ -n "$DEVICEQUERY_BIN" ]]; then
  run_cmd "Run cuda-samples deviceQuery" "$DEVICEQUERY_BIN" && ok "deviceQuery OK" || warn "deviceQuery exists but failed"

elif [[ -n "$DEVICEQUERY_DIR" ]]; then
  echo "${BOLD}==>${RESET} Found deviceQuery sources: $DEVICEQUERY_DIR"

  if [[ "$(id -u)" -eq 0 ]]; then
    # root -> build in-place
    BUILD_DIR="$DEVICEQUERY_DIR"
  else
    # non-root -> build in temp
    BUILD_DIR="$(mktemp -d)"
    cp -a "$DEVICEQUERY_DIR/." "$BUILD_DIR/"
  fi

  if run_cmd "Build deviceQuery (make)" bash -lc "cd '$BUILD_DIR' && make -j\$(nproc)"; then
    if [[ -x "$BUILD_DIR/deviceQuery" ]]; then
      run_cmd "Run deviceQuery" "$BUILD_DIR/deviceQuery" && ok "deviceQuery OK (built from sources)" || warn "deviceQuery built but failed to run"
    else
      warn "make succeeded but deviceQuery binary not found at $BUILD_DIR/deviceQuery"
    fi
  else
    warn "Failed to build deviceQuery"
  fi

  [[ "$BUILD_DIR" != "$DEVICEQUERY_DIR" ]] && rm -rf "$BUILD_DIR"


else
  warn "cuda-samples deviceQuery not found (no binary, no sources) — skipping"
fi


########## SECTION CUDNN ################################################################

section "cuDNN"
if have dpkg && dpkg -l | grep -E "libcudnn8|libcudnn" >/dev/null 2>&1; then
  run_cmd "dpkg cuDNN packages" bash -lc 'dpkg -l | grep -E "libcudnn8|libcudnn" || true'
  ok "cuDNN package(s) present"
else
  warn "cuDNN packages not found via dpkg (maybe not installed or different naming)"
fi

# dlopen common cuDNN SONAMEs
if py_dlopen "libcudnn.so.8" >/dev/null 2>&1 || py_dlopen "libcudnn.so" >/dev/null 2>&1; then
  ok "cuDNN shared library loadable"
else
  fail "cuDNN shared library not loadable (libcudnn.so*)"
fi


########## SECTION TENSORRT ############################################################

section "TensorRT"

TRTEXEC=""
for p in \
  /usr/src/tensorrt/bin/trtexec \
  /usr/bin/trtexec \
  /usr/local/bin/trtexec
do
  [[ -x "$p" ]] && TRTEXEC="$p" && break
done

if [[ -n "$TRTEXEC" ]]; then
  echo "${BOLD}==>${RESET} Detect trtexec version (from --help header)"

  # With "set -euo pipefail", trtexec may return non-zero even for --help.
  # So we capture output while explicitly ignoring the exit code.
  set +e
  TRT_OUT="$("$TRTEXEC" --help 2>&1)"
  TRT_RC=$?
  set -e

  # Parse just the first line and extract [TensorRT vXXXX]
  TRT_LINE="$(printf '%s\n' "$TRT_OUT" | head -n1)"
  TRT_TAG="$(printf '%s\n' "$TRT_LINE" | grep -oE '\[TensorRT v[0-9]+\]' | tr -d '[]' || true)"

  if [[ -n "$TRT_TAG" ]]; then
    ok "trtexec present (${TRT_TAG}) (rc=${TRT_RC})"
  else
    ok "trtexec present (rc=${TRT_RC})"
    echo "    $TRT_LINE"
  fi
else
  warn "trtexec not found (TensorRT samples/tools may not be installed)"
fi

# python import + dlopen
python3 - <<'PY' >/dev/null 2>&1 && ok "Python TensorRT import OK" || fail "Python TensorRT import FAILED"
import tensorrt as trt
print(trt.__version__)
PY

if py_dlopen "libnvinfer.so.8" >/dev/null 2>&1 || py_dlopen "libnvinfer.so" >/dev/null 2>&1; then
  ok "TensorRT shared library loadable"
else
  fail "TensorRT shared library not loadable (libnvinfer.so*)"
fi


################## SECTION VPI ###########################################################

section "VPI"

if have dpkg && dpkg -l | grep -E "vpi|libnvvpi" >/dev/null 2>&1; then
  run_cmd "dpkg VPI packages" bash -lc 'dpkg -l | grep -E "vpi|libnvvpi" || true'
  ok "VPI package(s) present"
else
  warn "VPI packages not found via dpkg (maybe not installed or different naming)"
fi

# Runtime smoke test (no compiling samples): Python import + optional version print
python3 - <<'PY' >/dev/null 2>&1 && ok "Python VPI import OK" || fail "Python VPI import FAILED"
import vpi
# vpi.__version__ may or may not exist depending on bindings, so don't rely on it.
print("vpi import ok")
PY

# Shared library load check (VPI 1.x typically uses libnvvpi.so.1)
if py_dlopen "libnvvpi.so.1" >/dev/null 2>&1 || py_dlopen "libnvvpi.so" >/dev/null 2>&1; then
  ok "VPI shared library loadable"
else
  warn "VPI shared library not loadable via dlopen (libnvvpi.so*)"
fi

# Optional: detect sample sources so we can report them (but we don't build)
if [[ -d /opt/nvidia/vpi1/samples ]]; then
  ok "VPI sample sources present: /opt/nvidia/vpi1/samples (not built)"
else
  warn "VPI sample sources not found under /opt/nvidia/vpi1/samples"
fi



#################### SECTION OPENCV #####################################################

section "OpenCV"

OPENCV_PROBE_OUT="$(
python3 - <<'PY'
import sys

try:
    import cv2
except Exception as e:
    print("OPENCV_OK=0")
    print("OPENCV_ERR=%s" % str(e).replace("\n"," "))
    sys.exit(0)

print("OPENCV_OK=1")
print("OPENCV_VER=%s" % cv2.__version__)

# Strict CUDA detection: only PASS if build info explicitly says YES.
cuda_enabled = False
cuda_line = ""

try:
    bi = cv2.getBuildInformation()
    for line in bi.splitlines():
        # Different OpenCV versions spell this differently
        if "NVIDIA CUDA" in line or "Use CUDA" in line:
            cuda_line = line.strip()
            if "YES" in line:
                cuda_enabled = True
            break
except Exception:
    pass

print("OPENCV_CUDA=%d" % (1 if cuda_enabled else 0))
print("OPENCV_CUDA_LINE=%s" % cuda_line.replace("\n"," "))
sys.exit(0)
PY
)"

OPENCV_OK_VAL="$(echo "$OPENCV_PROBE_OUT" | awk -F= '/^OPENCV_OK=/{print $2}' | tail -n1)"
OPENCV_VER_VAL="$(echo "$OPENCV_PROBE_OUT" | awk -F= '/^OPENCV_VER=/{print $2}' | tail -n1)"
OPENCV_CUDA_VAL="$(echo "$OPENCV_PROBE_OUT" | awk -F= '/^OPENCV_CUDA=/{print $2}' | tail -n1)"
OPENCV_ERR_VAL="$(echo "$OPENCV_PROBE_OUT" | sed -n 's/^OPENCV_ERR=//p' | tail -n1)"
OPENCV_CUDA_LINE="$(echo "$OPENCV_PROBE_OUT" | sed -n 's/^OPENCV_CUDA_LINE=//p' | tail -n1)"

# 1) OpenCV installed?
if [[ "$OPENCV_OK_VAL" == "1" ]]; then
  ok "OpenCV installed (cv2 ${OPENCV_VER_VAL})"
else
  fail "OpenCV not installed (python cv2 import failed): ${OPENCV_ERR_VAL:-unknown error}"
fi

# 2) OpenCV + CUDA enabled?
if [[ "$OPENCV_OK_VAL" == "1" ]]; then
  if [[ "$OPENCV_CUDA_VAL" == "1" ]]; then
    ok "OpenCV CUDA enabled"
    [[ -n "$OPENCV_CUDA_LINE" ]] && echo "    $OPENCV_CUDA_LINE"
  else
    fail "OpenCV CUDA NOT enabled"
    [[ -n "$OPENCV_CUDA_LINE" ]] && echo "    $OPENCV_CUDA_LINE"
  fi
fi


################## SECTION VisionWorks #################################################

section "VisionWorks (deprecated but included in 4.6.x)"
if have dpkg && dpkg -l | grep -E "visionworks|libvisionworks" >/dev/null 2>&1; then
  run_cmd "dpkg VisionWorks packages" bash -lc 'dpkg -l | grep -E "visionworks|libvisionworks" || true'
  ok "VisionWorks package(s) present"
else
  warn "VisionWorks packages not found (may not have been installed in your SDK selection)"
fi

section "Multimedia API / GStreamer (key Jetson elements)"
if have gst-inspect-1.0; then
  ok "GStreamer present (gst-inspect-1.0)"
  # These elements are commonly used on Jetson; absence suggests multimedia stack got damaged.
  for elem in nvvidconv nvv4l2decoder nvv4l2h264enc; do
    if gst-inspect-1.0 "$elem" >/dev/null 2>&1; then
      ok "gst element present: $elem"
    else
      warn "gst element missing: $elem (package selection can vary, but this is a common Jetson check)"
    fi
  done
else
  warn "gst-inspect-1.0 not found (GStreamer not installed?)"
fi

section "NVIDIA Container Runtime / Docker"
if have docker; then
  run_cmd "docker --version" docker --version && ok "docker present"
  if docker info 2>/dev/null | grep -qi nvidia; then
    ok "docker info mentions NVIDIA runtime (good sign)"
  else
    warn "docker present but NVIDIA runtime not obvious in 'docker info' output"
  fi
  if have nvidia-container-cli; then
    run_cmd "nvidia-container-cli --version" nvidia-container-cli --version && ok "nvidia-container-cli present"
  else
    warn "nvidia-container-cli not found (nvidia-container-runtime tooling may be missing)"
  fi
else
  warn "docker not found (container checks skipped)"
fi

section "Optional SDKs (if installed): DeepStream / Triton"
if have deepstream-app; then
  run_cmd "deepstream-app --version-all" deepstream-app --version-all && ok "DeepStream runnable"
else
  warn "DeepStream not found (skipping)"
fi

# Triton on Jetson is often packaged as libs; try common patterns:
if have dpkg && dpkg -l | grep -Ei "triton|libtritonserver" >/dev/null 2>&1; then
  run_cmd "dpkg Triton packages" bash -lc 'dpkg -l | grep -Ei "triton|libtritonserver" || true'
  ok "Triton package(s) present"
else
  warn "Triton not found (skipping)"
fi

echo
echo "${BOLD}=== SUMMARY ===${RESET}"
echo "Log: $LOG_FILE"
echo "PASS: $PASS_CNT  WARN: $WARN_CNT  FAIL: $FAIL_CNT"

# Non-zero exit if any hard failures:
if [[ "$FAIL_CNT" -gt 0 ]]; then
  exit 1
fi
exit 0
