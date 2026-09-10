// JNI seam between UniConnect and the vendored whisper.cpp (MIT, see whisper/LICENSE).
//
// Deliberately thin: one context per transcription, one synchronous call, no state of its own.
// Progress and cancellation travel back into Kotlin through a small listener object, so a
// dictation the reader abandons stops the model instead of finishing into nothing.

#include <jni.h>
#include <android/log.h>

#include <string>
#include <vector>

#include "whisper.h"

#define TAG "uniwhisper"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

namespace {

/// What the listener passed from Kotlin can be asked, resolved once per transcription.
struct listener_bridge {
    JNIEnv *  env       = nullptr;
    jobject   listener  = nullptr;
    jmethodID on_progress = nullptr;
    jmethodID is_cancelled = nullptr;

    bool valid() const { return listener != nullptr && on_progress != nullptr && is_cancelled != nullptr; }
};

void report_progress(struct whisper_context * /*ctx*/, struct whisper_state * /*state*/, int progress, void * user_data) {
    auto * bridge = static_cast<listener_bridge *>(user_data);
    if (bridge == nullptr || !bridge->valid()) return;
    bridge->env->CallVoidMethod(bridge->listener, bridge->on_progress, static_cast<jint>(progress));
    if (bridge->env->ExceptionCheck()) bridge->env->ExceptionClear();
}

bool should_abort(void * user_data) {
    auto * bridge = static_cast<listener_bridge *>(user_data);
    if (bridge == nullptr || !bridge->valid()) return false;
    jboolean cancelled = bridge->env->CallBooleanMethod(bridge->listener, bridge->is_cancelled);
    if (bridge->env->ExceptionCheck()) {
        bridge->env->ExceptionClear();
        return false;
    }
    return cancelled == JNI_TRUE;
}

} // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_unixcision_uniconnect_android_data_WhisperNative_openModel(JNIEnv * env, jobject /*thiz*/, jstring model_path) {
    const char * path = env->GetStringUTFChars(model_path, nullptr);
    if (path == nullptr) return 0;
    whisper_context_params params = whisper_context_default_params();
    // There is no GPU backend in this build; asking for one only prints a warning per call.
    params.use_gpu = false;
    params.flash_attn = false;
    whisper_context * context = whisper_init_from_file_with_params(path, params);
    env->ReleaseStringUTFChars(model_path, path);
    if (context == nullptr) LOGW("the model at the given path could not be opened");
    return reinterpret_cast<jlong>(context);
}

JNIEXPORT void JNICALL
Java_com_unixcision_uniconnect_android_data_WhisperNative_closeModel(JNIEnv * /*env*/, jobject /*thiz*/, jlong handle) {
    if (handle == 0) return;
    whisper_free(reinterpret_cast<whisper_context *>(handle));
}

/// Transcribes 16 kHz mono float samples and returns the text, or null when the model failed or
/// the listener asked for the run to stop.
JNIEXPORT jstring JNICALL
Java_com_unixcision_uniconnect_android_data_WhisperNative_transcribe(
        JNIEnv * env, jobject /*thiz*/, jlong handle, jfloatArray samples, jint threads, jstring language, jobject listener) {
    if (handle == 0) return nullptr;
    auto * context = reinterpret_cast<whisper_context *>(handle);

    listener_bridge bridge;
    bridge.env = env;
    if (listener != nullptr) {
        jclass cls = env->GetObjectClass(listener);
        bridge.listener = listener;
        bridge.on_progress = env->GetMethodID(cls, "onProgress", "(I)V");
        bridge.is_cancelled = env->GetMethodID(cls, "cancelled", "()Z");
        if (env->ExceptionCheck()) {
            env->ExceptionClear();
            bridge.on_progress = nullptr;
            bridge.is_cancelled = nullptr;
        }
    }

    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_realtime   = false;
    params.print_progress   = false;
    params.print_timestamps = false;
    params.print_special    = false;
    params.translate        = false;
    params.no_timestamps    = true;
    params.single_segment   = false;
    params.suppress_blank   = true;
    params.n_threads        = threads > 0 ? threads : 4;
    params.offset_ms        = 0;
    params.no_context       = true;

    std::string tag;
    if (language != nullptr) {
        const char * chars = env->GetStringUTFChars(language, nullptr);
        if (chars != nullptr) {
            tag.assign(chars);
            env->ReleaseStringUTFChars(language, chars);
        }
    }
    if (tag.empty() || tag == "auto") {
        params.language = "auto";
        params.detect_language = false;
    } else {
        params.language = tag.c_str();
    }

    if (bridge.valid()) {
        params.progress_callback           = report_progress;
        params.progress_callback_user_data = &bridge;
        params.abort_callback              = should_abort;
        params.abort_callback_user_data    = &bridge;
    }

    jfloat * audio = env->GetFloatArrayElements(samples, nullptr);
    if (audio == nullptr) return nullptr;
    const jsize count = env->GetArrayLength(samples);

    const int status = whisper_full(context, params, audio, count);
    env->ReleaseFloatArrayElements(samples, audio, JNI_ABORT);

    if (status != 0) {
        LOGW("whisper_full returned %d", status);
        return nullptr;
    }
    if (bridge.valid() && should_abort(&bridge)) return nullptr;

    std::string text;
    const int segments = whisper_full_n_segments(context);
    for (int i = 0; i < segments; ++i) {
        const char * segment = whisper_full_get_segment_text(context, i);
        if (segment != nullptr) text.append(segment);
    }
    return env->NewStringUTF(text.c_str());
}

/// The instruction sets whisper.cpp believes it has, for the report and for diagnosis.
JNIEXPORT jstring JNICALL
Java_com_unixcision_uniconnect_android_data_WhisperNative_systemInfo(JNIEnv * env, jobject /*thiz*/) {
    return env->NewStringUTF(whisper_print_system_info());
}

} // extern "C"
