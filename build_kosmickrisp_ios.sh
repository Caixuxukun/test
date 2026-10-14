#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MESA_DIR="${MESA_DIR:-${SCRIPT_DIR}}"
echo "==> [1/7] Navigating to Mesa repository: ${MESA_DIR}"
cd "${MESA_DIR}"

BUILD_DIR="${MESA_DIR}/build-ios-arm64"
HOST_BUILD_DIR="${MESA_DIR}/build-host-tools"
HOST_TOOLS_BIN="${HOST_BUILD_DIR}/tools-bin"
CROSS_FILE="${MESA_DIR}/ios_arm64_cross.ini"

echo "==> [2/7] Discovering iPhoneOS SDK environment..."

IPHONEOS_SDK_PATH="${IPHONEOS_SDK_PATH:-}"

if [ -n "${IPHONEOS_SDK_PATH}" ] && [ -d "${IPHONEOS_SDK_PATH}" ]; then
    echo "    Using iPhoneOS SDK from environment: ${IPHONEOS_SDK_PATH}"

elif command -v xcrun &>/dev/null; then
    IPHONEOS_SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)
    if [ -n "${IPHONEOS_SDK_PATH}" ] && [ -d "${IPHONEOS_SDK_PATH}" ]; then
        echo "    Discovered iPhoneOS SDK via xcrun: ${IPHONEOS_SDK_PATH}"
    fi

else
    CANDIDATE_PATHS=(
        "${HOME}/iPhoneOS.sdk"
        "${HOME}/sdks/iPhoneOS.sdk"
        "/usr/share/SDKs/iPhoneOS.sdk"
        "/opt/theos/sdks/iPhoneOS.sdk"
        "${HOME}/Downloads/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
    )
    for candidate in "${CANDIDATE_PATHS[@]}"; do
        if [ -d "${candidate}" ]; then
            IPHONEOS_SDK_PATH="${candidate}"
            echo "    Found iPhoneOS SDK in system path: ${IPHONEOS_SDK_PATH}"
            break
        fi
    done
fi

if [ -z "${IPHONEOS_SDK_PATH}" ] || [ ! -d "${IPHONEOS_SDK_PATH}" ]; then
    echo "==============================================================================" >&2
    echo "ERROR: iPhoneOS SDK could not be located." >&2
    echo "==============================================================================" >&2
    echo "Note: 'xcrun' is an Apple macOS utility and is not present on Linux." >&2
    echo "To resolve this, specify the path to your extracted iPhoneOS.sdk directory:" >&2
    echo "" >&2
    echo "  export IPHONEOS_SDK_PATH=/path/to/iPhoneOS.sdk" >&2
    echo "  ./build_kosmickrisp_ios.sh" >&2
    echo "" >&2
    echo "Or place the SDK at: ~/iPhoneOS.sdk or /usr/share/SDKs/iPhoneOS.sdk" >&2
    echo "==============================================================================" >&2
    exit 1
fi
echo "    Target SDK: ${IPHONEOS_SDK_PATH}"

if command -v xcrun &>/dev/null; then
    SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)"
    SDK_MAJOR="${SDK_VERSION%%.*}"
    echo "    iPhoneOS SDK version: ${SDK_VERSION:-unknown}"
    if [ -n "${SDK_MAJOR}" ] && [ "${SDK_MAJOR}" -lt 26 ] 2>/dev/null; then
        echo "WARNING: iPhoneOS SDK ${SDK_VERSION} is older than 26; Metal 4 headers are" >&2
        echo "         missing, so compiling the driver will fail. Select Xcode 26+." >&2
    fi
fi

CC_BIN="clang"
CXX_BIN="clang++"
if command -v xcrun &>/dev/null; then
    _cc="$(xcrun --sdk iphoneos --find clang 2>/dev/null || true)"
    _cxx="$(xcrun --sdk iphoneos --find clang++ 2>/dev/null || true)"
    [ -n "${_cc}" ] && [ -x "${_cc}" ] && CC_BIN="${_cc}"
    [ -n "${_cxx}" ] && [ -x "${_cxx}" ] && CXX_BIN="${_cxx}"
fi
echo "    iOS C compiler:   ${CC_BIN}"
echo "    iOS C++ compiler: ${CXX_BIN}"

echo "==> [3/7] Ensuring core Vulkan symbols are exported for launcher dynamic loading..."
KK_INSTANCE_C="${MESA_DIR}/src/kosmickrisp/vulkan/kk_instance.c"

if ! grep -q "PUBLIC VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr" "${KK_INSTANCE_C}"; then
    echo "    Patching ${KK_INSTANCE_C} with public standalone Vulkan exports..."
    cat << 'EOF' >> "${KK_INSTANCE_C}"

PUBLIC VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vkGetInstanceProcAddr(VkInstance instance, const char *pName)
{
   return kk_GetInstanceProcAddr(instance, pName);
}

PUBLIC VKAPI_ATTR VkResult VKAPI_CALL
vkCreateInstance(const VkInstanceCreateInfo *pCreateInfo,
                 const VkAllocationCallbacks *pAllocator,
                 VkInstance *pInstance)
{
   return kk_CreateInstance(pCreateInfo, pAllocator, pInstance);
}

PUBLIC VKAPI_ATTR VkResult VKAPI_CALL
vkEnumerateInstanceExtensionProperties(const char *pLayerName,
                                       uint32_t *pPropertyCount,
                                       VkExtensionProperties *pProperties)
{
   return kk_EnumerateInstanceExtensionProperties(pLayerName, pPropertyCount, pProperties);
}

PUBLIC VKAPI_ATTR VkResult VKAPI_CALL
vkEnumerateInstanceVersion(uint32_t *pApiVersion)
{
   return kk_EnumerateInstanceVersion(pApiVersion);
}
EOF
    echo "    Core symbols successfully appended to kk_instance.c."
else
    echo "    Core Vulkan symbols already defined in kk_instance.c."
fi

if grep -q "'apple'" "${MESA_DIR}/meson.options" 2>/dev/null; then
    PLATFORM_FLAG="-Dplatforms=apple"
else
    PLATFORM_FLAG="-Dplatforms=macos"
fi
echo "    Using platform configuration: ${PLATFORM_FLAG}"

host_tools_present() {
    [ -x "$1/mesa_clc" ] && [ -x "$1/vtn_bindgen2" ] && [ -x "$1/kk_clc" ]
}

if [ -n "${HOST_TOOLS_DIR:-}" ] && host_tools_present "${HOST_TOOLS_DIR}"; then
    echo "==> [4/7] Using prebuilt host tools from HOST_TOOLS_DIR=${HOST_TOOLS_DIR}"
    HOST_TOOLS_BIN="${HOST_TOOLS_DIR}"
else
    echo "==> [4/7] Building host-side compiler tools natively (mesa_clc, vtn_bindgen2, kk_clc)..."

    if [ "$(uname -s)" != "Darwin" ]; then
        echo "ERROR: building the host tools needs a macOS host (KosmicKrisp is Darwin-only)." >&2
        echo "       Build them on a Mac and re-run with HOST_TOOLS_DIR=/path/to/dir" >&2
        echo "       containing mesa_clc, vtn_bindgen2 and kk_clc." >&2
        exit 1
    fi

    if command -v brew &>/dev/null; then
        LLVM_PREFIX="$(brew --prefix llvm 2>/dev/null || true)"
        if [ -n "${LLVM_PREFIX}" ] && [ -d "${LLVM_PREFIX}/bin" ]; then
            export PATH="${LLVM_PREFIX}/bin:${PATH}"
        fi
    fi
    if ! command -v llvm-config &>/dev/null; then
        echo "ERROR: llvm-config not found. Run: brew install llvm libclc spirv-llvm-translator spirv-tools" >&2
        exit 1
    fi
    echo "    Host LLVM: $(llvm-config --version) ($(command -v llvm-config))"

    rm -rf "${HOST_BUILD_DIR}"

    meson setup "${HOST_BUILD_DIR}" \
        ${PLATFORM_FLAG} \
        -Dllvm=enabled \
        -Dmesa-clc=enabled \
        -Dprecomp-compiler=enabled \
        -Dinstall-mesa-clc=true \
        -Dinstall-precomp-compiler=true \
        -Dvulkan-drivers=kosmickrisp \
        -Dgallium-drivers= \
        -Dbuildtype=release \
        -Dopengl=false \
        -Degl=disabled \
        -Dglx=disabled \
        -Dgbm=disabled \
        -Dzstd=disabled \
        --prefer-static

    ninja -C "${HOST_BUILD_DIR}" \
        src/compiler/clc/mesa_clc \
        src/compiler/spirv/vtn_bindgen2 \
        src/kosmickrisp/clc/kk_clc

    mkdir -p "${HOST_TOOLS_BIN}"
    cp "${HOST_BUILD_DIR}/src/compiler/clc/mesa_clc"          "${HOST_TOOLS_BIN}/"
    cp "${HOST_BUILD_DIR}/src/compiler/spirv/vtn_bindgen2"    "${HOST_TOOLS_BIN}/"
    cp "${HOST_BUILD_DIR}/src/kosmickrisp/clc/kk_clc"         "${HOST_TOOLS_BIN}/"
    echo "    Host tools installed in: ${HOST_TOOLS_BIN}"
fi

if ! host_tools_present "${HOST_TOOLS_BIN}"; then
    echo "ERROR: host tools missing in ${HOST_TOOLS_BIN} (need mesa_clc, vtn_bindgen2, kk_clc)." >&2
    exit 1
fi

export PATH="${HOST_TOOLS_BIN}:${PATH}"

echo "==> [5/7] Generating Meson cross-compilation file: ${CROSS_FILE}"
IOS_TARGET_VERSION="${IOS_TARGET_VERSION:-26.0}"
TARGET_TRIPLE="arm64-apple-ios${IOS_TARGET_VERSION}"
echo "    Targeting iOS version: ${IOS_TARGET_VERSION} (${TARGET_TRIPLE})"

cat << EOF > "${CROSS_FILE}"
[binaries]
c = '${CC_BIN}'
cpp = '${CXX_BIN}'
objc = '${CC_BIN}'
objcpp = '${CXX_BIN}'
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-target', '${TARGET_TRIPLE}', '-isysroot', '${IPHONEOS_SDK_PATH}', '-miphoneos-version-min=${IOS_TARGET_VERSION}', '-O3', '-fPIC']
cpp_args = ['-target', '${TARGET_TRIPLE}', '-isysroot', '${IPHONEOS_SDK_PATH}', '-miphoneos-version-min=${IOS_TARGET_VERSION}', '-O3', '-fPIC']
objc_args = ['-target', '${TARGET_TRIPLE}', '-isysroot', '${IPHONEOS_SDK_PATH}', '-miphoneos-version-min=${IOS_TARGET_VERSION}', '-O3', '-fPIC', '-Wno-unguarded-availability-new']
objcpp_args = ['-target', '${TARGET_TRIPLE}', '-isysroot', '${IPHONEOS_SDK_PATH}', '-miphoneos-version-min=${IOS_TARGET_VERSION}', '-O3', '-fPIC', '-Wno-unguarded-availability-new']
c_link_args = ['-target', '${TARGET_TRIPLE}', '-isysroot', '${IPHONEOS_SDK_PATH}', '-miphoneos-version-min=${IOS_TARGET_VERSION}', '-Wl,-undefined,dynamic_lookup']
cpp_link_args = ['-target', '${TARGET_TRIPLE}', '-isysroot', '${IPHONEOS_SDK_PATH}', '-miphoneos-version-min=${IOS_TARGET_VERSION}', '-Wl,-undefined,dynamic_lookup']
objc_link_args = ['-target', '${TARGET_TRIPLE}', '-isysroot', '${IPHONEOS_SDK_PATH}', '-miphoneos-version-min=${IOS_TARGET_VERSION}', '-Wl,-undefined,dynamic_lookup']
objcpp_link_args = ['-target', '${TARGET_TRIPLE}', '-isysroot', '${IPHONEOS_SDK_PATH}', '-miphoneos-version-min=${IOS_TARGET_VERSION}', '-Wl,-undefined,dynamic_lookup']

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF

echo "==> [6/7] Configuring Meson build for KosmicKrisp (iOS cross)..."

if [ -d "${BUILD_DIR}" ]; then
    echo "    Existing build directory found; wiping for clean build..."
    rm -rf "${BUILD_DIR}"
fi

meson setup "${BUILD_DIR}" \
    --cross-file "${CROSS_FILE}" \
    ${PLATFORM_FLAG} \
    -Dllvm=disabled \
    -Dmesa-clc=system \
    -Dprecomp-compiler=system \
    -Dspirv-tools=disabled \
    -Dgallium-drivers= \
    -Dvulkan-drivers=kosmickrisp \
    -Dbuildtype=release \
    -Db_ndebug=true \
    -Dopengl=false \
    -Degl=disabled \
    -Dglx=disabled \
    -Dgbm=disabled \
    -Dtools=[] \
    -Dzstd=disabled \
    --prefer-static

echo "==> [7/7] Compiling standalone dynamic library with Ninja..."
ninja -C "${BUILD_DIR}" src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib

OUTPUT_DYLIB="${BUILD_DIR}/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib"

if [ -f "${OUTPUT_DYLIB}" ]; then
    echo "=============================================================================="
    echo "BUILD SUCCESSFUL!"
    echo "Output Artifact: ${OUTPUT_DYLIB}"
    echo "=============================================================================="

    if command -v nm &>/dev/null; then
        echo "Exported Core Vulkan Symbols in Artifact:"
        nm -gU "${OUTPUT_DYLIB}" | grep -E "_(vkGetInstanceProcAddr|vkCreateInstance|vk_icdGetInstanceProcAddr)" || true
    fi
else
    echo "ERROR: Artifact ${OUTPUT_DYLIB} was not produced." >&2
    exit 1
fi
