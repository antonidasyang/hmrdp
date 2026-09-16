// hilog 封装
#ifndef HMRDP_HM_LOG_H
#define HMRDP_HM_LOG_H

#include <hilog/log.h>

// 应用日志的 domain 只能是 16 位（0x0000~0xFFFF），超出范围 hilog 直接丢弃、一行都不出——
// 之前的 0xD2550 就是这么让原生日志在手机上全军覆没的
#define HM_DOMAIN 0x2550
#define HM_TAG "HMRDP"

#define HMLOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, HM_DOMAIN, HM_TAG, __VA_ARGS__)
#define HMLOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN, HM_DOMAIN, HM_TAG, __VA_ARGS__)
#define HMLOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, HM_DOMAIN, HM_TAG, __VA_ARGS__)

#endif // HMRDP_HM_LOG_H
