cmake_minimum_required(VERSION 3.22.1)
project(uniwhisper CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(WHISPER_DIR ${CMAKE_CURRENT_SOURCE_DIR}/whisper)

# The vendored commit is what whisper.cpp reports as its own version at runtime. The file is not
# named VERSION on purpose: whisper/ used to sit on the include path and a case-insensitive
# filesystem then resolved the C++ standard header <version> to it.
file(READ "${WHISPER_DIR}/whisper-commit.txt" VENDORED_COMMIT)
string(STRIP "${VENDORED_COMMIT}" VENDORED_COMMIT)

# Only the CPU backend. Every other ggml backend is opt-in and its sources are not vendored, so
# turning them off is what keeps this tree small rather than a preference about speed.
set(GGML_CPU        ON  CACHE BOOL "" FORCE)
set(GGML_METAL      OFF CACHE BOOL "" FORCE)
set(GGML_VULKAN     OFF CACHE BOOL "" FORCE)
set(GGML_OPENCL     OFF CACHE BOOL "" FORCE)
set(GGML_BLAS       OFF CACHE BOOL "" FORCE)
set(GGML_RPC        OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP     OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE  OFF CACHE BOOL "" FORCE)
set(GGML_CPU_KLEIDIAI OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS   OFF CACHE BOOL "" FORCE)

# ARMv8.2 half-precision and dot-product kernels, which is what makes a quantised model usable on
# a phone at all. Every arm64 SoC from 2018 on has them; the loader refuses to load this library
# on a CPU that does not advertise both, and the app then transcribes somewhere else instead of
# taking an illegal instruction.
if (ANDROID_ABI STREQUAL "arm64-v8a")
    set(GGML_CPU_ARM_ARCH "armv8.2-a+fp16+dotprod" CACHE STRING "" FORCE)
endif()

add_subdirectory(${WHISPER_DIR}/ggml ${CMAKE_CURRENT_BINARY_DIR}/ggml)

find_library(LOG_LIB log)

add_library(uniwhisper SHARED ${WHISPER_DIR}/src/whisper.cpp uniwhisper.cpp)
target_compile_definitions(uniwhisper PRIVATE GGML_USE_CPU WHISPER_VERSION="${VENDORED_COMMIT}")
target_include_directories(uniwhisper PRIVATE
    ${WHISPER_DIR}/src
    ${WHISPER_DIR}/include
    ${WHISPER_DIR}/ggml/include
    ${WHISPER_DIR}/ggml/src
    ${WHISPER_DIR}/ggml/src/ggml-cpu)
target_compile_options(uniwhisper PRIVATE -O3 -fvisibility=hidden -fvisibility-inlines-hidden -ffunction-sections -fdata-sections)
if (ANDROID_ABI STREQUAL "arm64-v8a")
    target_compile_options(uniwhisper PRIVATE -march=armv8.2-a+fp16+dotprod)
endif()
target_link_options(uniwhisper PRIVATE -Wl,--gc-sections -Wl,--exclude-libs,ALL)
target_link_libraries(uniwhisper PRIVATE ${LOG_LIB} android ggml)
