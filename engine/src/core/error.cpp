#include "core/error.h"

#include <cstdio>
#include <cstring>
#include <mutex>

#include <deque>

namespace {
thread_local std::string g_last_error;
ke_log_cb g_log_cb = nullptr;
void* g_log_user = nullptr;
std::mutex g_log_mutex;
bool g_queue_enabled = false;
int g_queue_min_level = KE_LOG_INFO;
std::deque<std::string> g_queue;
constexpr size_t kQueueCap = 1000;
}  // namespace

extern "C" {

KE_API const char* ke_version(void) { return "0.1.0"; }

KE_API void ke_set_log_callback(ke_log_cb cb, void* user) {
    std::lock_guard<std::mutex> lock(g_log_mutex);
    g_log_cb = cb;
    g_log_user = user;
}

KE_API const char* ke_last_error(void) { return g_last_error.c_str(); }

KE_API void ke_log_set_queue(int enabled, int min_level) {
    std::lock_guard<std::mutex> lock(g_log_mutex);
    g_queue_enabled = enabled != 0;
    g_queue_min_level = min_level;
    if (!g_queue_enabled) g_queue.clear();
}

KE_API int ke_log_drain(char* out, size_t cap, size_t* needed) {
    std::string joined;
    {
        std::lock_guard<std::mutex> lock(g_log_mutex);
        if (!out || cap == 0) {  // size query: do not consume
            size_t n = 1;
            for (auto& s : g_queue) n += s.size();
            if (needed) *needed = n;
            return KE_OK;
        }
        for (auto& s : g_queue) joined += s;
        size_t n = joined.size() + 1;
        if (needed) *needed = n;
        if (cap < n) return KE_ERR_BUFFER_TOO_SMALL;  // caller re-queries; nothing consumed
        g_queue.clear();
    }
    memcpy(out, joined.data(), joined.size());
    out[joined.size()] = '\0';
    return KE_OK;
}

}  // extern "C"

namespace ke {

int fail_str(int code, const std::string& msg) {
    g_last_error = msg;
    log(KE_LOG_ERROR, "%s", msg.c_str());
    return code;
}

int fail(int code, const char* fmt, ...) {
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    return fail_str(code, buf);
}

void logv(int level, const char* fmt, va_list ap) {
    char buf[2048];
    vsnprintf(buf, sizeof(buf), fmt, ap);
    std::lock_guard<std::mutex> lock(g_log_mutex);
    if (g_queue_enabled && level >= g_queue_min_level) {
        if (g_queue.size() >= kQueueCap) g_queue.pop_front();
        g_queue.push_back(std::to_string(level) + "\t" + buf + "\n");
    }
    if (g_log_cb) {
        g_log_cb(level, buf, g_log_user);
    } else if (!g_queue_enabled && level >= KE_LOG_INFO) {
        static const char* names[] = {"D", "I", "W", "E"};
        fprintf(stderr, "[ke:%s] %s\n", names[level & 3], buf);
    }
}

void log(int level, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    logv(level, fmt, ap);
    va_end(ap);
}

int write_out_string(const std::string& s, char* out, size_t cap, size_t* needed) {
    if (needed) *needed = s.size() + 1;
    if (!out || cap == 0) return KE_OK;  // size query
    if (cap < s.size() + 1) {
        memcpy(out, s.data(), cap - 1);
        out[cap - 1] = '\0';
        return KE_ERR_BUFFER_TOO_SMALL;
    }
    memcpy(out, s.data(), s.size());
    out[s.size()] = '\0';
    return KE_OK;
}

int report_progress(ke_progress_cb cb, void* user, float fraction, const char* stage) {
    if (!cb) return KE_OK;
    if (cb(fraction, stage, user) != 0) {
        return fail(KE_ERR_CANCELLED, "cancelled during %s", stage);
    }
    return KE_OK;
}

}  // namespace ke
