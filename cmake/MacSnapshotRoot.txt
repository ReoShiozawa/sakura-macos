# Copyright (c) 2026 Unofficial Sakura macOS port contributors
# SPDX-License-Identifier: Zlib
cmake_minimum_required(VERSION 3.21)
project(sakura LANGUAGES CXX)
include(${PROJECT_SOURCE_DIR}/cmake/UnofficialVersion.cmake)

# This public snapshot intentionally contains no legacy Windows application,
# installer, prebuilt archive, image collection or Windows-only submodule.
if(APPLE)
  option(SAKURA_BUILD_MAC_APP "Build the experimental AppKit application" ON)
  option(SAKURA_BUILD_UNIVERSAL "Build arm64 and x86_64 macOS binaries" OFF)
  if(SAKURA_BUILD_UNIVERSAL AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING
      "macOS target architectures" FORCE)
  endif()
  if(SAKURA_BUILD_MAC_APP)
    enable_language(OBJCXX)
  endif()
endif()

include(CTest)
option(SAKURA_BUILD_BENCHMARKS "Build opt-in core performance benchmarks" OFF)
add_subdirectory(core)
add_subdirectory(app)
if(BUILD_TESTING)
  add_subdirectory(tests/portable)
  find_package(Python3 QUIET COMPONENTS Interpreter)
  if(Python3_Interpreter_FOUND)
    add_test(NAME MacPublicationSourceChecks
      COMMAND "${Python3_EXECUTABLE}" "${PROJECT_SOURCE_DIR}/tools/check_macos_publication.py" --mac-snapshot)
    add_test(NAME MacPublicationCheckerTests
      COMMAND "${Python3_EXECUTABLE}" "${PROJECT_SOURCE_DIR}/tests/portable/PublicationCheckTests.py")
  endif()
endif()
if(APPLE AND SAKURA_BUILD_MAC_APP)
  add_subdirectory(platform/mac)
  add_subdirectory(ui/mac)
  if(BUILD_TESTING)
    add_subdirectory(tests/mac)
  endif()
endif()
if(SAKURA_BUILD_BENCHMARKS)
  add_subdirectory(tests/performance)
endif()
