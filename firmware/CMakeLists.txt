cmake_minimum_required(VERSION 3.13)

# Require the Pico SDK path
if(NOT DEFINED ENV{PICO_SDK_PATH})
  message(FATAL_ERROR "PICO_SDK_PATH not set. Example: export PICO_SDK_PATH=$HOME/pico-sdk")
endif()
include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(cdc_uac2_pico C CXX ASM)
pico_sdk_init()

set(SRC_DIR ${CMAKE_CURRENT_LIST_DIR}/src)
# Pick up any .c/.cpp you drop into src/
file(GLOB APP_SOURCES CONFIGURE_DEPENDS
     "${SRC_DIR}/*.c" "${SRC_DIR}/*.cpp")

if(NOT APP_SOURCES)
  message(FATAL_ERROR "No sources found in ${SRC_DIR}. Add main.c/.cpp etc.")
endif()

add_executable(cdc_uac2 ${APP_SOURCES})
target_include_directories(cdc_uac2 PRIVATE ${SRC_DIR})
target_compile_features(cdc_uac2 PRIVATE c_std_11 cxx_std_17)
target_compile_options(cdc_uac2 PRIVATE -Wall -Wextra)

# TinyUSB is provided by the Pico SDK
target_link_libraries(cdc_uac2
    pico_stdlib
    tinyusb_device
    tinyusb_board
    # pico_audio pico_audio_i2s   # uncomment when you add I²S
)

# Use USB stdio; disable UART stdio
pico_enable_stdio_usb(cdc_uac2 1)
pico_enable_stdio_uart(cdc_uac2 0)

# Produce UF2/ELF/BIN/MAP
pico_add_extra_outputs(cdc_uac2)