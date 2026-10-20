// Native entry point used directly by MainFlutterWindow.swift.
// Matches src/flutter.rs. Dart's generated FFI ABI remains unchanged.
#ifndef G3_NATIVE_BRIDGE_H
#define G3_NATIVE_BRIDGE_H
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
bool rustdesk_core_main(void);
#ifdef __cplusplus
}
#endif
#endif
