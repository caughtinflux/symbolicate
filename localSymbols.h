#ifndef SYMBOLICATE_LOCALSYMBOLS_H_
#define SYMBOLICATE_LOCALSYMBOLS_H_

#ifdef __cplusplus
extern "C" {
#endif

NSString *nameForLocalSymbol(uint32_t dylibOffset, uint32_t symbolAddress);
NSString *demangle(NSString *mangled);

#ifdef __cplusplus
}
#endif

#endif // SYMBOLICATE_LOCALSYMBOLS_H_

/* vim: set ft=objcpp ff=unix sw=4 ts=4 tw=80 expandtab: */
