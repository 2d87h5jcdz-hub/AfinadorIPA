cmake_minimum_required(VERSION 3.22.1)
project(pestana_studio LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Código C++ compartilhado com o iOS (amp neural NAM + modulação) e bibliotecas vendorizadas.
set(REPO_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../../..)
set(VENDOR ${REPO_ROOT}/Vendor)
file(GLOB NAM_SOURCES ${VENDOR}/NAM/*.cpp ${VENDOR}/NAM/wavenet/*.cpp)

find_package(oboe REQUIRED CONFIG)

add_library(pestana_studio SHARED
    jni_bridge.cpp
    studio_engine.cpp
    mixer.cpp
    fx.cpp
    ${REPO_ROOT}/Afinador/GuitarFX/GuitarFXCore.cpp
    ${NAM_SOURCES})

target_include_directories(pestana_studio PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${REPO_ROOT}/Afinador/GuitarFX
    ${VENDOR} ${VENDOR}/NAM ${VENDOR}/eigen ${VENDOR}/nlohmann)

target_compile_definitions(pestana_studio PRIVATE NAM_SAMPLE_FLOAT=1 NAM_ENABLE_A2_FAST=1)
target_compile_options(pestana_studio PRIVATE -O3 -fno-math-errno -Wno-deprecated-declarations)

target_link_libraries(pestana_studio oboe::oboe log android)
