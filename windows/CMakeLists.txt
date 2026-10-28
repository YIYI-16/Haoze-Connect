# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(hiddify LANGUAGES CXX)

# The name of the executable created for the application. Haoze Connect keeps
# its own on-disk binary name, independent of upstream Hiddify ("Hiddify.exe").
# Keep this in sync with windows/runner/Runner.rc (OriginalFilename) and the
# installer/zip packaging in windows/packaging + scripts/haoze-*.
set(BINARY_NAME "HaozeConnect")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# install(FILES "../hiddify-core/bin/hiddify-core.dll" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
#  COMPONENT Runtime)

install(FILES "../hiddify-core/bin/hiddify-core.dll" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
COMPONENT Runtime RENAME hiddify-core.dll)

install(FILES "../hiddify-core/bin/libcronet.dll" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
COMPONENT Runtime RENAME libcronet.dll)

install(FILES "../hiddify-core/bin/HiddifyCli.exe" DESTINATION "${CMAKE_INSTALL_PREFIX}"
COMPONENT Runtime RENAME HiddifyCli.exe)


if(PLUGIN_BUNDLED_LIBRARIES)
  # vclibs ships a fixed, older CRT. Never let a plugin replace the runtime
  # selected below from the compiler's own Visual Studio installation.
  list(FILTER PLUGIN_BUNDLED_LIBRARIES EXCLUDE REGEX
    "[/\\\\]([Mm][Ss][Vv][Cc][Pp]140[^/\\\\]*|[Vv][Cc][Rr][Uu][Nn][Tt][Ii][Mm][Ee]140[^/\\\\]*|[Cc][Oo][Nn][Cc][Rr][Tt]140)\\.dll$")
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# InstallRequiredSystemLibraries normally searches every installed VS. Limit
# it to the installation owning the selected cl.exe, including side-by-side
# toolsets, and fail rather than silently packaging an older redistributable.
if(NOT MSVC)
  message(FATAL_ERROR "Windows runtime packaging requires an MSVC toolchain")
endif()
get_filename_component(_haoze_compiler_bin "${CMAKE_CXX_COMPILER}" DIRECTORY)
get_filename_component(_haoze_toolset "${_haoze_compiler_bin}/../../.." ABSOLUTE)
get_filename_component(_haoze_toolset_version "${_haoze_toolset}" NAME)
get_filename_component(_haoze_vc_root "${_haoze_toolset}/../../.." ABSOLUTE)
if(NOT _haoze_toolset_version MATCHES "^14\\.[0-9]+\\.[0-9]+$" OR
   NOT IS_DIRECTORY "${_haoze_vc_root}/Redist/MSVC")
  message(FATAL_ERROR "Cannot locate MSVC redistributables for ${CMAKE_CXX_COMPILER}")
endif()
set(MSVC_REDIST_DIR "")
file(GLOB _haoze_redist_candidates LIST_DIRECTORIES TRUE
  "${_haoze_vc_root}/Redist/MSVC/*")
set(_haoze_redist_version "0")
foreach(_candidate IN LISTS _haoze_redist_candidates)
  get_filename_component(_version "${_candidate}" NAME)
  if(_version MATCHES "^14\\.[0-9]+\\.[0-9]+$" AND
     _version VERSION_GREATER_EQUAL _haoze_toolset_version AND
     _version VERSION_GREATER _haoze_redist_version)
    set(MSVC_REDIST_DIR "${_candidate}")
    set(_haoze_redist_version "${_version}")
  endif()
endforeach()
if(NOT MSVC_REDIST_DIR)
  message(FATAL_ERROR "Install MSVC redistributable files >= ${_haoze_toolset_version} in ${_haoze_vc_root}/Redist/MSVC")
endif()
set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
set(CMAKE_INSTALL_DEBUG_LIBRARIES FALSE)
set(CMAKE_INSTALL_DEBUG_LIBRARIES_ONLY FALSE)
set(CMAKE_INSTALL_UCRT_LIBRARIES FALSE)
set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS "")
# A reused build directory can contain a cached CRT path from another VS.
unset(MSVC_CRT_DIR CACHE)
unset(MSVC_CRT_DIR)
include(InstallRequiredSystemLibraries)
set(_haoze_required_crt msvcp140.dll vcruntime140.dll)
if(CMAKE_MSVC_ARCH STREQUAL "x64")
  list(APPEND _haoze_required_crt vcruntime140_1.dll)
endif()
foreach(_required IN LISTS _haoze_required_crt)
  if(NOT EXISTS "${MSVC_CRT_DIR}/${_required}")
    message(FATAL_ERROR "Missing selected MSVC runtime: ${MSVC_CRT_DIR}/${_required}")
  endif()
endforeach()
if(NOT CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS)
  message(FATAL_ERROR "CMake could not discover the selected MSVC runtime")
endif()
find_program(_haoze_powershell NAMES powershell.exe)
if(NOT _haoze_powershell)
  message(FATAL_ERROR "Windows PowerShell is required to validate MSVC runtime files")
endif()
execute_process(COMMAND "${_haoze_powershell}" -NoLogo -NoProfile -NonInteractive
  -File "${CMAKE_CURRENT_SOURCE_DIR}/scripts/check_msvc_runtime.ps1"
  -RuntimeDirectory "${MSVC_CRT_DIR}"
  -MinimumVersion "${_haoze_toolset_version}"
  -Architecture "${CMAKE_MSVC_ARCH}"
  RESULT_VARIABLE _haoze_runtime_result)
if(NOT _haoze_runtime_result EQUAL 0)
  message(FATAL_ERROR "Selected MSVC runtime validation failed (${_haoze_runtime_result})")
endif()
message(STATUS "Bundling MSVC runtime from ${MSVC_CRT_DIR}")
install(FILES ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS}
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" CONFIGURATIONS Profile Release
  COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
