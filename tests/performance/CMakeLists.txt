# Opt-in developer benchmark. It is intentionally not a CTest test: wall-clock
# timings vary by hardware and build mode and must not become a flaky gate.
add_executable(sakura_core_performance CorePerformance.cpp)
target_link_libraries(sakura_core_performance PRIVATE sakura_app)
target_compile_features(sakura_core_performance PRIVATE cxx_std_20)
set_target_properties(sakura_core_performance PROPERTIES CXX_EXTENSIONS OFF)
if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
  target_compile_options(sakura_core_performance PRIVATE -Wall -Wextra -Wpedantic)
endif()
if(APPLE AND TARGET sakura_platform_mac)
  target_link_libraries(sakura_core_performance PRIVATE sakura_platform_mac)
  target_compile_definitions(sakura_core_performance PRIVATE
    SAKURA_BENCHMARK_WITH_CORETEXT=1)
endif()
