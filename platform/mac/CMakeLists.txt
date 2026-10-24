find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(COREFOUNDATION_FRAMEWORK CoreFoundation REQUIRED)
find_library(CORETEXT_FRAMEWORK CoreText REQUIRED)

add_library(sakura_platform_mac STATIC
  src/CoreTextMetrics.mm
  src/GrepFileTransaction.mm
  src/MacEncodingService.mm
  src/StringBridge.mm
)

target_include_directories(sakura_platform_mac
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(sakura_platform_mac
  PUBLIC
    sakura::portable_core
    ${FOUNDATION_FRAMEWORK}
    ${COREFOUNDATION_FRAMEWORK}
    ${CORETEXT_FRAMEWORK}
)

target_compile_features(sakura_platform_mac PUBLIC cxx_std_20)
target_compile_options(sakura_platform_mac PRIVATE
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
)

set_target_properties(sakura_platform_mac PROPERTIES
  CXX_EXTENSIONS OFF
  OBJCXX_EXTENSIONS OFF
  OBJCXX_STANDARD 20
  OBJCXX_STANDARD_REQUIRED ON
  POSITION_INDEPENDENT_CODE ON
)

if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang")
  target_compile_options(sakura_platform_mac PRIVATE -Wall -Wextra -Wpedantic)
endif()
