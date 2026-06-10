#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#if defined(_M_IX86) && defined(_WIN32_WINNT) && (_WIN32_WINNT < 0x0600)

namespace {

typedef DWORD(WINAPI* PFN_FLS_ALLOC)(PFLS_CALLBACK_FUNCTION);
typedef BOOL(WINAPI* PFN_FLS_FREE)(DWORD);
typedef PVOID(WINAPI* PFN_FLS_GET_VALUE)(DWORD);
typedef BOOL(WINAPI* PFN_FLS_SET_VALUE)(DWORD, PVOID);
typedef BOOL(WINAPI* PFN_INITIALIZE_CRITICAL_SECTION_EX)(LPCRITICAL_SECTION, DWORD, DWORD);

struct FlsDispatch {
  PFN_FLS_ALLOC alloc;
  PFN_FLS_FREE free_slot;
  PFN_FLS_GET_VALUE get_value;
  PFN_FLS_SET_VALUE set_value;
  PFN_INITIALIZE_CRITICAL_SECTION_EX initialize_critical_section_ex;
};

volatile LONG g_fls_init_state = 0;
CRITICAL_SECTION g_fls_lock;
PFLS_CALLBACK_FUNCTION g_fls_callbacks[1088] = {};
FlsDispatch g_fls_dispatch = {};

template <typename T, size_t N>
size_t ArrayCount(const T (&)[N]) {
  return N;
}

void EnsureFlsCompatInitialized() {
  if (g_fls_init_state == 2) {
    return;
  }

  if (InterlockedCompareExchange(&g_fls_init_state, 1, 0) == 0) {
    InitializeCriticalSection(&g_fls_lock);

    HMODULE kernel32 = GetModuleHandleW(L"kernel32.dll");
    if (kernel32 != nullptr) {
      g_fls_dispatch.alloc =
          reinterpret_cast<PFN_FLS_ALLOC>(GetProcAddress(kernel32, "FlsAlloc"));
      g_fls_dispatch.free_slot =
          reinterpret_cast<PFN_FLS_FREE>(GetProcAddress(kernel32, "FlsFree"));
      g_fls_dispatch.get_value =
          reinterpret_cast<PFN_FLS_GET_VALUE>(GetProcAddress(kernel32, "FlsGetValue"));
      g_fls_dispatch.set_value =
          reinterpret_cast<PFN_FLS_SET_VALUE>(GetProcAddress(kernel32, "FlsSetValue"));
      g_fls_dispatch.initialize_critical_section_ex =
          reinterpret_cast<PFN_INITIALIZE_CRITICAL_SECTION_EX>(
              GetProcAddress(kernel32, "InitializeCriticalSectionEx"));
    }

    InterlockedExchange(&g_fls_init_state, 2);
    return;
  }

  while (g_fls_init_state != 2) {
    Sleep(0);
  }
}

bool HasNativeFls() {
  EnsureFlsCompatInitialized();
  return g_fls_dispatch.alloc != nullptr && g_fls_dispatch.free_slot != nullptr &&
         g_fls_dispatch.get_value != nullptr && g_fls_dispatch.set_value != nullptr;
}

}  // namespace

extern "C" DWORD WINAPI XpCompatFlsAlloc(PFLS_CALLBACK_FUNCTION callback) {
  if (HasNativeFls()) {
    return g_fls_dispatch.alloc(callback);
  }

  const DWORD slot = TlsAlloc();
  if (slot == TLS_OUT_OF_INDEXES) {
    return slot;
  }
  if (slot < ArrayCount(g_fls_callbacks)) {
    EnterCriticalSection(&g_fls_lock);
    g_fls_callbacks[slot] = callback;
    LeaveCriticalSection(&g_fls_lock);
  }
  return slot;
}

extern "C" BOOL WINAPI XpCompatFlsFree(DWORD slot) {
  if (HasNativeFls()) {
    return g_fls_dispatch.free_slot(slot);
  }

  PFLS_CALLBACK_FUNCTION callback = nullptr;
  if (slot < ArrayCount(g_fls_callbacks)) {
    EnterCriticalSection(&g_fls_lock);
    callback = g_fls_callbacks[slot];
    g_fls_callbacks[slot] = nullptr;
    LeaveCriticalSection(&g_fls_lock);
  }

  if (callback != nullptr) {
    PVOID value = TlsGetValue(slot);
    if (value != nullptr || GetLastError() == ERROR_SUCCESS) {
      callback(value);
    }
  }

  return TlsFree(slot);
}

extern "C" PVOID WINAPI XpCompatFlsGetValue(DWORD slot) {
  if (HasNativeFls()) {
    return g_fls_dispatch.get_value(slot);
  }
  return TlsGetValue(slot);
}

extern "C" BOOL WINAPI XpCompatFlsSetValue(DWORD slot, PVOID value) {
  if (HasNativeFls()) {
    return g_fls_dispatch.set_value(slot, value);
  }
  return TlsSetValue(slot, value);
}

extern "C" BOOL WINAPI XpCompatInitializeCriticalSectionEx(
    LPCRITICAL_SECTION critical_section,
    DWORD spin_count,
    DWORD flags) {
  EnsureFlsCompatInitialized();
  if (g_fls_dispatch.initialize_critical_section_ex != nullptr) {
    return g_fls_dispatch.initialize_critical_section_ex(critical_section, spin_count, flags);
  }
  (void)flags;
  return InitializeCriticalSectionAndSpinCount(critical_section, spin_count);
}

extern "C" {

PFN_FLS_ALLOC xp_compat_imp_FlsAlloc = &XpCompatFlsAlloc;
PFN_FLS_FREE xp_compat_imp_FlsFree = &XpCompatFlsFree;
PFN_FLS_GET_VALUE xp_compat_imp_FlsGetValue = &XpCompatFlsGetValue;
PFN_FLS_SET_VALUE xp_compat_imp_FlsSetValue = &XpCompatFlsSetValue;
PFN_INITIALIZE_CRITICAL_SECTION_EX xp_compat_imp_InitializeCriticalSectionEx =
    &XpCompatInitializeCriticalSectionEx;

}

#pragma comment(linker, "/alternatename:__imp__FlsAlloc@4=_xp_compat_imp_FlsAlloc")
#pragma comment(linker, "/alternatename:__imp__FlsFree@4=_xp_compat_imp_FlsFree")
#pragma comment(linker, "/alternatename:__imp__FlsGetValue@4=_xp_compat_imp_FlsGetValue")
#pragma comment(linker, "/alternatename:__imp__FlsSetValue@8=_xp_compat_imp_FlsSetValue")
#pragma comment(linker, "/alternatename:__imp__InitializeCriticalSectionEx@12=_xp_compat_imp_InitializeCriticalSectionEx")
#pragma comment(linker, "/alternatename:_FlsAlloc@4=_XpCompatFlsAlloc@4")
#pragma comment(linker, "/alternatename:_FlsFree@4=_XpCompatFlsFree@4")
#pragma comment(linker, "/alternatename:_FlsGetValue@4=_XpCompatFlsGetValue@4")
#pragma comment(linker, "/alternatename:_FlsSetValue@8=_XpCompatFlsSetValue@8")
#pragma comment(linker, "/alternatename:_InitializeCriticalSectionEx@12=_XpCompatInitializeCriticalSectionEx@12")

#endif
