#!/usr/bin/env bash
# ===============================================================================
# Build Automation Script: KosmicKrisp Vulkan Driver (.dylib) for iOS 26 arm64
# Targeted for iOS Minecraft Java Launcher Frameworks (e.g., PojavLauncher / LWJGL)
# ===============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Directory Context
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MESA_DIR="${MESA_DIR:-${SCRIPT_DIR}}"
echo "==> [1/6] Navigating to Mesa repository: ${MESA_DIR}"
cd "${MESA_DIR}"

BUILD_DIR="${MESA_DIR}/build-ios-arm64"
CROSS_FILE="${MESA_DIR}/ios_arm64_cross.ini"

# ------------------------------------------------------------------------------
# 2. Environment Discovery
# ------------------------------------------------------------------------------
echo "==> [2/6] Discovering iPhoneOS SDK environment..."

IPHONEOS_SDK_PATH=""

# A. Check if user passed IPHONEOS_SDK_PATH as an environment variable
if [ -n "${IPHONEOS_SDK_PATH:-}" ] && [ -d "${IPHONEOS_SDK_PATH}" ]; then
    echo "    Using iPhoneOS SDK from environment: ${IPHONEOS_SDK_PATH}"

# B. If on macOS with Xcode / xcrun available, query xcrun
elif command -v xcrun &>/dev/null; then
    IPHONEOS_SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)
    if [ -n "${IPHONEOS_SDK_PATH}" ] && [ -d "${IPHONEOS_SDK_PATH}" ]; then
        echo "    Discovered iPhoneOS SDK via xcrun: ${IPHONEOS_SDK_PATH}"
    fi

# C. If on Linux (or xcrun unavailable), search common SDK directories
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

# ------------------------------------------------------------------------------
# 3. Core Vulkan Symbol Export Verification / Patch
# Ensure standalone .dylib exports vkGetInstanceProcAddr and vkCreateInstance
# ------------------------------------------------------------------------------
echo "==> [3/6] Ensuring core Vulkan symbols are exported for launcher dynamic loading..."
KK_INSTANCE_C="${MESA_DIR}/src/kosmickrisp/vulkan/kk_instance.c"

# Check if public vkGetInstanceProcAddr and vkCreateInstance wrappers exist; inject if missing
if ! grep -q "PUBLIC VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr" "${KK_INSTANCE_C}"; then
    echo "    Patching ${KK_INSTANCE_C} with public standalone Vulkan exports..."
    cat << 'EOF' >> "${KK_INSTANCE_C}"

/* Standalone dynamic loader exports for launcher frameworks (LWJGL / dlsym) */
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

# ------------------------------------------------------------------------------
# 4. Cross-Compilation Setup (Meson Cross File)
# ------------------------------------------------------------------------------
echo "==> [4/6] Generating Meson cross-compilation file: ${CROSS_FILE}"
IOS_TARGET_VERSION="${IOS_TARGET_VERSION:-26.0}"
TARGET_TRIPLE="arm64-apple-ios${IOS_TARGET_VERSION}"
echo "    Targeting iOS version: ${IOS_TARGET_VERSION} (${TARGET_TRIPLE})"

cat << EOF > "${CROSS_FILE}"
[binaries]
c = 'clang'
cpp = 'clang++'
objc = 'clang'
objcpp = 'clang++'
ar = 'ar'
strip = 'strip'
# Provide a usable pkg-config for Meson host/tool detection instead of 'false'
# which causes Meson to try /usr/bin/false and fail. We rely on PATH so 'pkg-config'
# will resolve to the host pkg-config installed by CI (Homebrew).
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

# ------------------------------------------------------------------------------
# 5. Meson Configuration and Setup
# ------------------------------------------------------------------------------
echo "==> [5/6] Configuring Meson build for KosmicKrisp..."

# In Mesa's meson.options, Apple platforms (Metal/QuartzCore/Darwin) map to 'macos'.
# Check if current tree supports 'apple' or 'macos' to satisfy -Dplatforms= flag safely.
if grep -q "'apple'" "${MESA_DIR}/meson.options" 2>/dev/null; then
    PLATFORM_FLAG="-Dplatforms=apple"
else
    PLATFORM_FLAG="-Dplatforms=macos"
fi
echo "    Using platform configuration: ${PLATFORM_FLAG}"

# Wipe build directory if requested or reconfiguring
if [ -d "${BUILD_DIR}" ]; then
    echo "    Existing build directory found; wiping for clean build..."
    rm -rf "${BUILD_DIR}"
fi

# Disable LLVM to avoid Meson trying to find/build an LLVM subproject when
# it's not required for this iOS standalone dylib build. This is the minimal
# fix to prevent meson configure from failing when no llvm.wrap/subproject is
# available. If you need LLVM later, add a proper subproject/llvm.wrap or set
# -Dllvm=true and ensure llvm-config is available on the host.
meson setup "${BUILD_DIR}" \
    --cross-file "${CROSS_FILE}" \
    ${PLATFORM_FLAG} \
    -Dllvm=false \
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

# ------------------------------------------------------------------------------
# 6. Standalone Artifact Compilation & Symbol Verification
# ------------------------------------------------------------------------------
echo "==> [6/6] Compiling standalone dynamic library with Ninja..."
ninja -C "${BUILD_DIR}" src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib

OUTPUT_DYLIB="${BUILD_DIR}/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib"

if [ -f "${OUTPUT_DYLIB}" ]; then
    echo "=============================================================================="
    echo "BUILD SUCCESSFUL!"
    echo "Output Artifact: ${OUTPUT_DYLIB}"
    echo "=============================================================================="

    # Perform symbol inspection if nm / otool are available
    if command -v nm &>/dev/null; then
        echo "Exported Core Vulkan Symbols in Artifact:"
        nm -gU "${OUTPUT_DYLIB}" | grep -E "_(vkGetInstanceProcAddr|vkCreateInstance|vk_icdGetInstanceProcAddr)" || true
    fi
else
    echo "ERROR: Artifact ${OUTPUT_DYLIB} was not produced." >&2
    exit 1
fi
