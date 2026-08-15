#include_next <bits/libc-header-start.h>

/* CUDA 12.9 declares these C23 math names without glibc's noexcept spec. */
#undef __GLIBC_USE_IEC_60559_FUNCS_EXT_C23
#define __GLIBC_USE_IEC_60559_FUNCS_EXT_C23 0
