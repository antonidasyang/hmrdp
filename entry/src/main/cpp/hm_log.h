// hilog 封装
#ifndef HMRDP_HM_LOG_H
#define HMRDP_HM_LOG_H

#include <hilog/log.h>

#define HM_DOMAIN 0xD2550
#define HM_TAG "HMRDP"

#define HMLOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, HM_DOMAIN, HM_TAG, __VA_ARGS__)
#define HMLOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN, HM_DOMAIN, HM_TAG, __VA_ARGS__)
#define HMLOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, HM_DOMAIN, HM_TAG, __VA_ARGS__)

#endif // HMRDP_HM_LOG_H
