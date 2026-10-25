add_library(sakura_portable_core STATIC
  src/edit/EditEngine.cpp
  src/encoding/EncodingService.cpp
  src/encoding/Utf8Codec.cpp
  src/encoding/Utf16Codec.cpp
  src/layout/LayoutEngine.cpp
  src/layout/IndexedLayout.cpp
  src/search/SearchEngine.cpp
  src/search/BracketSearch.cpp
  src/search/BufferUText.cpp
  src/syntax/SyntaxHighlighter.cpp
  src/syntax/LanguageSyntax.cpp
  src/syntax/IndexedSyntax.cpp
  src/syntax/CustomSyntax.cpp
  src/text/TextBuffer.cpp
)

add_library(sakura::portable_core ALIAS sakura_portable_core)

target_include_directories(sakura_portable_core
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_features(sakura_portable_core PUBLIC cxx_std_20)

# The macOS SDK supplies the ICU C API through libicucore.  Other hosts use
# their package manager's ICU (declared in vcpkg.json for the Windows build).
if(APPLE)
  find_library(SAKURA_ICUCORE_LIBRARY icucore REQUIRED)
  target_link_libraries(sakura_portable_core PRIVATE ${SAKURA_ICUCORE_LIBRARY})
else()
  find_package(ICU REQUIRED COMPONENTS uc i18n)
  target_link_libraries(sakura_portable_core PRIVATE ICU::uc ICU::i18n)
endif()

set_target_properties(sakura_portable_core PROPERTIES
  CXX_EXTENSIONS OFF
  POSITION_INDEPENDENT_CODE ON
)

if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
  target_compile_options(sakura_portable_core PRIVATE -Wall -Wextra -Wpedantic)
endif()
