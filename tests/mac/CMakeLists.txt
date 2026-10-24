add_executable(sakura_mac_encoding_tests
  MacEncodingTests.cpp
)

target_link_libraries(sakura_mac_encoding_tests PRIVATE
  sakura_app
  sakura_platform_mac
)
target_compile_features(sakura_mac_encoding_tests PRIVATE cxx_std_20)
set_target_properties(sakura_mac_encoding_tests PROPERTIES CXX_EXTENSIONS OFF)

if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang")
  target_compile_options(sakura_mac_encoding_tests PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_test(NAME MacEncodingIntegrationTests COMMAND sakura_mac_encoding_tests)

add_executable(sakura_grep_file_transaction_tests GrepFileTransactionTests.mm)
target_link_libraries(sakura_grep_file_transaction_tests PRIVATE sakura_platform_mac)
target_compile_features(sakura_grep_file_transaction_tests PRIVATE cxx_std_20)
set_target_properties(sakura_grep_file_transaction_tests PROPERTIES
  CXX_EXTENSIONS OFF
  OBJCXX_EXTENSIONS OFF
  OBJCXX_STANDARD 20
  OBJCXX_STANDARD_REQUIRED ON
)
if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang")
  target_compile_options(sakura_grep_file_transaction_tests PRIVATE -Wall -Wextra -Wpedantic)
endif()
add_test(NAME GrepFileTransactionTests COMMAND sakura_grep_file_transaction_tests)

foreach(ui_test IN ITEMS EditorNavigation EditorSearch GrepWorkflow EditorSettings EditorRendering PublicationBranding)
  string(TOLOWER "${ui_test}" ui_test_name)
  add_executable(sakura_${ui_test_name}_tests ${ui_test}Tests.mm)
  target_link_libraries(sakura_${ui_test_name}_tests PRIVATE sakura_ui_mac)
  target_compile_features(sakura_${ui_test_name}_tests PRIVATE cxx_std_20)
  target_compile_options(sakura_${ui_test_name}_tests PRIVATE -fobjc-arc)
  target_link_options(sakura_${ui_test_name}_tests PRIVATE -Wl,-ObjC)
  set_target_properties(sakura_${ui_test_name}_tests PROPERTIES
    CXX_EXTENSIONS OFF OBJCXX_EXTENSIONS OFF OBJCXX_STANDARD 20
    OBJCXX_STANDARD_REQUIRED ON)
  add_test(NAME ${ui_test}Tests COMMAND sakura_${ui_test_name}_tests)
endforeach()
