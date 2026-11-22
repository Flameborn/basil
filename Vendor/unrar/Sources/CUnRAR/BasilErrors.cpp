// Ours, not UnRAR's. The library keeps its error state in one global ErrorHandler
// (unrar/global.hpp), and the DLL API returns that state from every call. Two archives read on
// two threads at once would see each other's errors. Package.swift defines ErrHandler as
// (*BasilUnRARErrorHandler()), so every use of the global in the unmodified sources goes to
// this thread's own handler instead.
#include "unrar/rar.hpp"
#include "include/CUnRAR.h"

ErrorHandler *BasilUnRARErrorHandler()
{
  static thread_local ErrorHandler handler;
  return &handler;
}

// The state also stays set after a failed call until the next RAROpenArchiveEx, so one damaged
// file would fail every later call. Basil clears it before each header and file call.
extern "C" void BasilUnRARClearErrors(void)
{
  BasilUnRARErrorHandler()->Clean();
}
