// Thread-local last error + log callback shared by the whole engine.
#pragma once
#include <string>
#include <cstdarg>
#include "karaoke_engine.h"

namespace ke {

// Records the message for ke_last_error() on this thread and returns `code`
// so call sites can write: return ke::fail(KE_ERR_IO, "cannot open %s", path);
int fail(int code, const char* fmt, ...);
int fail_str(int code, const std::string& msg);

void log(int level, const char* fmt, ...);
void logv(int level, const char* fmt, va_list ap);

#define KE_LOGD(...) ::ke::log(KE_LOG_DEBUG, __VA_ARGS__)
#define KE_LOGI(...) ::ke::log(KE_LOG_INFO,  __VA_ARGS__)
#define KE_LOGW(...) ::ke::log(KE_LOG_WARN,  __VA_ARGS__)
#define KE_LOGE(...) ::ke::log(KE_LOG_ERROR, __VA_ARGS__)

// Helper for the "query then fill" string output pattern.
int write_out_string(const std::string& s, char* out, size_t cap, size_t* needed);

// Progress helper: returns KE_ERR_CANCELLED (and sets last error) when the
// callback asks to stop; KE_OK otherwise. Safe with a null callback.
int report_progress(ke_progress_cb cb, void* user, float fraction, const char* stage);

}  // namespace ke
