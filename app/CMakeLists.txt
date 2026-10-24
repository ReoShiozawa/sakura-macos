add_library(sakura_app STATIC
  src/CommandBus.cpp
  src/DocumentSession.cpp
)

target_include_directories(sakura_app
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(sakura_app PUBLIC sakura::portable_core)
target_compile_features(sakura_app PUBLIC cxx_std_20)

set_target_properties(sakura_app PROPERTIES
  CXX_EXTENSIONS OFF
  POSITION_INDEPENDENT_CODE ON
)

if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
  target_compile_options(sakura_app PRIVATE -Wall -Wextra -Wpedantic)
endif()
