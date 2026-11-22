// The UnRAR library's C API (unrar/dll.hpp) for Swift. dll.hpp defines its Windows-style
// types (HANDLE, LPARAM, UINT) only when _UNIX is set, which the library's own os.hpp does
// for its C++ sources.
#ifndef BASIL_CUNRAR_H
#define BASIL_CUNRAR_H

#include <wchar.h>

#ifndef _UNIX
#define _UNIX
#endif

#include "../unrar/dll.hpp"

#ifdef __cplusplus
extern "C" {
#endif
/// Clears this thread's UnRAR error state, which otherwise stays set after a failed call
/// (BasilErrors.cpp).
void BasilUnRARClearErrors(void);
#ifdef __cplusplus
}
#endif

#endif
