add_executable(sakura_tests
  DocumentCoreTests.cpp
)

target_link_libraries(sakura_tests PRIVATE sakura_app)
target_compile_features(sakura_tests PRIVATE cxx_std_20)
set_target_properties(sakura_tests PROPERTIES CXX_EXTENSIONS OFF)

if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
  target_compile_options(sakura_tests PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_test(NAME PortableCoreTests COMMAND sakura_tests)
