# HMRDP native 模块：NAPI 桥接层 + FreeRDP 静态内核
cmake_minimum_required(VERSION 3.5.0)
project(hmrdp)

set(TP_PREBUILT ${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/prebuilt/${OHOS_ARCH})

if(NOT EXISTS ${TP_PREBUILT}/lib/libfreerdp3.a)
    message(FATAL_ERROR
        "未找到 FreeRDP 预编译产物: ${TP_PREBUILT}\n请先运行 third_party/build_all.sh")
endif()

include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${TP_PREBUILT}/include/freerdp3
    ${TP_PREBUILT}/include/winpr3
)

add_library(hmrdp SHARED
    napi_init.cpp
    rdp_session.cpp
    input_mapper.cpp
)

target_link_libraries(hmrdp PUBLIC
    libace_napi.z.so
    libace_ndk.z.so
    libhilog_ndk.z.so
    libnative_window.so
    libnative_buffer.so
    # FreeRDP 静态内核（顺序敏感：client -> core -> winpr -> ssl -> crypto）
    ${TP_PREBUILT}/lib/libfreerdp-client3.a
    ${TP_PREBUILT}/lib/libfreerdp3.a
    ${TP_PREBUILT}/lib/libwinpr3.a
    ${TP_PREBUILT}/lib/libssl.a
    ${TP_PREBUILT}/lib/libcrypto.a
    libz.so
    libm.so
    libdl.so
)
