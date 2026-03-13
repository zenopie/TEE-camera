# CMakeLists.txt for frame-sign enclave
#
# Can be built standalone or as a subdirectory of Keystone examples.
# Standalone: cmake -DKEYSTONE_SDK_DIR=<path> ..

cmake_minimum_required(VERSION 3.10)
project(frame-sign C CXX)

if(NOT DEFINED KEYSTONE_SDK_DIR)
  message(FATAL_ERROR "Set KEYSTONE_SDK_DIR to the Keystone SDK install path")
endif()

# Use SDK macros only when building inside the Keystone tree (not standalone)
option(KEYSTONE_STANDALONE "Build without Eyrie runtime/packaging" ON)
if(NOT KEYSTONE_STANDALONE AND EXISTS "${KEYSTONE_SDK_DIR}/cmake/macros.cmake")
  include(${KEYSTONE_SDK_DIR}/cmake/macros.cmake)
  set(HAS_KEYSTONE_MACROS TRUE)
else()
  set(HAS_KEYSTONE_MACROS FALSE)
endif()

# SDK libraries
set(KEYSTONE_LIB_EAPP ${KEYSTONE_SDK_DIR}/lib/libkeystone-eapp.a)
set(KEYSTONE_LIB_EDGE ${KEYSTONE_SDK_DIR}/lib/libkeystone-edge.a)
set(KEYSTONE_LIB_HOST ${KEYSTONE_SDK_DIR}/lib/libkeystone-host.a)
set(KEYSTONE_LIB_VERIFIER ${KEYSTONE_SDK_DIR}/lib/libkeystone-verifier.a)

set(eapp_bin frame-sign)
set(eapp_src
  eapp/frame_sign.c
  eapp/edge_wrapper.c
  eapp/compact_ed25519.c
  eapp/compact_wipe.c
  eapp/c25519/ed25519.c
  eapp/c25519/edsign.c
  eapp/c25519/f25519.c
  eapp/c25519/fprime.c
  eapp/c25519/sha512.c
  eapp/c25519/c25519.c)
set(host_bin frame-sign-runner)
set(host_src host/host.cpp host/edge_wrapper.cpp)

# eapp - bare metal RISC-V enclave
add_executable(${eapp_bin} ${eapp_src})
target_link_libraries(${eapp_bin} ${KEYSTONE_LIB_EAPP} ${KEYSTONE_LIB_EDGE})
set_target_properties(${eapp_bin}
  PROPERTIES LINK_FLAGS "-nostdlib -static -T ${CMAKE_CURRENT_SOURCE_DIR}/app.lds")

target_include_directories(${eapp_bin}
  PUBLIC ${KEYSTONE_SDK_DIR}/include
  PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/eapp
  PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

# host - Linux userspace
add_executable(${host_bin} ${host_src})
target_link_libraries(${host_bin} ${KEYSTONE_LIB_HOST} ${KEYSTONE_LIB_EDGE} ${KEYSTONE_LIB_VERIFIER} pthread)
set_target_properties(${host_bin}
  PROPERTIES CXX_STANDARD 11 CXX_STANDARD_REQUIRED YES CXX_EXTENSIONS NO)
target_include_directories(${host_bin}
  PUBLIC ${KEYSTONE_SDK_DIR}/include
  PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/host
  PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

# Eyrie runtime + packaging (only when SDK macros are available)
if(HAS_KEYSTONE_MACROS)
  set(package_name "frame-sign.ke")
  set(package_script "./frame-sign-runner frame-sign eyrie-rt loader.bin")
  set(eyrie_plugins "none")
  set(eyrie_files_to_copy .options_log eyrie-rt loader.bin)

  add_eyrie_runtime(${eapp_bin}-eyrie ${eyrie_plugins} ${eyrie_files_to_copy})
  add_keystone_package(${eapp_bin}-package ${package_name} ${package_script}
    ${eyrie_files_to_copy} ${eapp_bin} ${host_bin})
  add_dependencies(${eapp_bin}-package ${eapp_bin}-eyrie)

  if(TARGET examples)
    add_dependencies(examples ${eapp_bin}-package)
  endif()
endif()
