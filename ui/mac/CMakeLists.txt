find_library(APPKIT_FRAMEWORK AppKit REQUIRED)
find_library(CORETEXT_FRAMEWORK CoreText REQUIRED)
find_library(COREGRAPHICS_FRAMEWORK CoreGraphics REQUIRED)

add_library(sakura_ui_mac STATIC
  src/SakuraAppDelegate.mm
  src/SakuraDocument.mm
  src/SakuraDurableFile.mm
  src/SakuraRecoveryStore.mm
  src/SakuraRecoveryWriter.mm
  src/SakuraEditorView.mm
  src/SakuraEditorCommands.mm
  src/SakuraEditorSettings.mm
  src/SakuraSyntaxSettings.mm
  src/SakuraSearchState.mm
  src/SakuraKeywordFile.mm
  src/SakuraWindowController.mm
)

target_include_directories(sakura_ui_mac
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(sakura_ui_mac
  PUBLIC
    sakura_app
    sakura_platform_mac
    ${APPKIT_FRAMEWORK}
    ${CORETEXT_FRAMEWORK}
    ${COREGRAPHICS_FRAMEWORK}
)

target_compile_features(sakura_ui_mac PUBLIC cxx_std_20)
target_compile_options(sakura_ui_mac PRIVATE
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
)

set_target_properties(sakura_ui_mac PROPERTIES
  CXX_EXTENSIONS OFF
  OBJCXX_EXTENSIONS OFF
  OBJCXX_STANDARD 20
  OBJCXX_STANDARD_REQUIRED ON
  POSITION_INDEPENDENT_CODE ON
)

if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang")
  target_compile_options(sakura_ui_mac PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_executable(SakuraEditor MACOSX_BUNDLE src/main.mm)

# Do not package extracted upstream artwork. Generate independent artwork from
# reviewable source; toolbar symbols are supplied by AppKit at runtime.
add_executable(sakura_icon_generator resources/GenerateAppIcon.mm)
target_link_libraries(sakura_icon_generator PRIVATE ${APPKIT_FRAMEWORK})
target_compile_options(sakura_icon_generator PRIVATE -fobjc-arc)
set(SAKURA_GENERATED_ICON "${CMAKE_CURRENT_BINARY_DIR}/generated/UnofficialSakura.icns")
add_custom_command(OUTPUT "${SAKURA_GENERATED_ICON}"
  COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/generated"
  COMMAND $<TARGET_FILE:sakura_icon_generator>
    "${CMAKE_CURRENT_BINARY_DIR}/generated/UnofficialSakura.iconset"
  COMMAND /usr/bin/iconutil -c icns
    "${CMAKE_CURRENT_BINARY_DIR}/generated/UnofficialSakura.iconset"
    -o "${SAKURA_GENERATED_ICON}"
  DEPENDS sakura_icon_generator resources/GenerateAppIcon.mm
  VERBATIM
)
add_custom_target(sakura_app_icon DEPENDS "${SAKURA_GENERATED_ICON}")
add_dependencies(SakuraEditor sakura_app_icon)
target_sources(SakuraEditor PRIVATE "${SAKURA_GENERATED_ICON}")
set_source_files_properties("${SAKURA_GENERATED_ICON}" PROPERTIES
  GENERATED TRUE MACOSX_PACKAGE_LOCATION "Resources")

set(SAKURA_LEGAL_DOCUMENTS
  "${PROJECT_SOURCE_DIR}/LICENSE"
  "${PROJECT_SOURCE_DIR}/LICENSE.macos"
  "${PROJECT_SOURCE_DIR}/NOTICE.md"
  "${PROJECT_SOURCE_DIR}/THIRD_PARTY_NOTICES.md"
  "${PROJECT_SOURCE_DIR}/docs/ASSET_PROVENANCE.md"
)
target_sources(SakuraEditor PRIVATE ${SAKURA_LEGAL_DOCUMENTS})
set_source_files_properties(${SAKURA_LEGAL_DOCUMENTS} PROPERTIES
  MACOSX_PACKAGE_LOCATION "Resources/Licenses")
set(SAKURA_MAC_BUNDLE_IDENTIFIER "local.unofficial-sakura.macos" CACHE STRING
  "Unofficial port Bundle ID; distributors must use their own identifier")
set(SAKURA_MAC_MINIMUM_SYSTEM_VERSION "${CMAKE_OSX_DEPLOYMENT_TARGET}")
if(NOT SAKURA_MAC_MINIMUM_SYSTEM_VERSION)
  set(SAKURA_MAC_MINIMUM_SYSTEM_VERSION "26.0")
endif()
target_link_libraries(SakuraEditor PRIVATE sakura_ui_mac)
target_compile_options(SakuraEditor PRIVATE
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
)
target_link_options(SakuraEditor PRIVATE -Wl,-ObjC)

set_target_properties(SakuraEditor PROPERTIES
  CXX_EXTENSIONS OFF
  OBJCXX_EXTENSIONS OFF
  OBJCXX_STANDARD 20
  OBJCXX_STANDARD_REQUIRED ON
  MACOSX_BUNDLE TRUE
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/resources/Info.plist.in
  MACOSX_BUNDLE_BUNDLE_NAME "Sakura macOS (Unofficial)"
  MACOSX_BUNDLE_ICON_FILE "UnofficialSakura.icns"
  MACOSX_BUNDLE_GUI_IDENTIFIER "${SAKURA_MAC_BUNDLE_IDENTIFIER}"
  MACOSX_BUNDLE_BUNDLE_VERSION "${SAKURA_RELEASE_BUNDLE_VERSION}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${SAKURA_RELEASE_NUMERIC_VERSION}"
)

if(BUILD_TESTING AND Python3_Interpreter_FOUND)
  add_test(NAME MacPublicationBundleChecks
    COMMAND "${Python3_EXECUTABLE}" "${PROJECT_SOURCE_DIR}/tools/check_macos_publication.py"
      --bundle "$<TARGET_BUNDLE_DIR:SakuraEditor>")
endif()

install(TARGETS SakuraEditor BUNDLE DESTINATION . COMPONENT Runtime)
# Ad-hoc sealing binds the plist/resources for integrity; it does not identify
# an Apple-verified developer and is not notarization.
install(CODE [[
  execute_process(COMMAND /usr/bin/codesign --force --sign - --timestamp=none
    "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/SakuraEditor.app"
    RESULT_VARIABLE seal_result)
  if(NOT seal_result EQUAL 0)
    message(FATAL_ERROR "Could not ad-hoc seal the installed application")
  endif()
]] COMPONENT Runtime)
install(FILES
  "${PROJECT_SOURCE_DIR}/README.md"
  "${PROJECT_SOURCE_DIR}/README.en.md"
  "${PROJECT_SOURCE_DIR}/CONTRIBUTING.md"
  "${PROJECT_SOURCE_DIR}/SECURITY.md"
  "${PROJECT_SOURCE_DIR}/sakura_editor_macos_port_design.md"
  ${SAKURA_LEGAL_DOCUMENTS}
  DESTINATION "Read Me and Licenses" COMPONENT Runtime)
install(FILES
  "${PROJECT_SOURCE_DIR}/docs/ASSET_PROVENANCE.md"
  "${PROJECT_SOURCE_DIR}/docs/RELEASING.md"
  "${PROJECT_SOURCE_DIR}/docs/macos-development.md"
  DESTINATION "Read Me and Licenses/docs" COMPONENT Runtime)

set(CPACK_GENERATOR "DragNDrop")
set(CPACK_PACKAGE_NAME "Sakura macOS (Unofficial)")
set(CPACK_PACKAGE_VENDOR "Unofficial Sakura macOS port contributors")
set(CPACK_PACKAGE_VERSION "${SAKURA_RELEASE_NUMERIC_VERSION}")
set(CPACK_PACKAGE_FILE_NAME "Sakura-macOS-${SAKURA_RELEASE_TAG}-universal")
set(CPACK_DMG_VOLUME_NAME "Sakura macOS ${SAKURA_RELEASE_DISPLAY_VERSION} (Unofficial)")
set(CPACK_DMG_FORMAT "UDZO")
set(CPACK_DMG_FILESYSTEM "APFS")
set(CPACK_COMPONENTS_ALL Runtime)
include(CPack)
