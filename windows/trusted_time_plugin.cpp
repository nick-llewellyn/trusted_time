#include "trusted_time_plugin.h"

// windows.h is already included via the header (FIX W1), but listing it here
// explicitly keeps the .cpp self-documenting and harmless (include guards
// prevent double inclusion).
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

namespace trusted_time {

// Registration
// static
void TrustedTimePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto plugin = std::make_unique<TrustedTimePlugin>(registrar);

  // Monotonic clock channel.
  auto monotonic_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "trusted_time/monotonic",
          &flutter::StandardMethodCodec::GetInstance());
  monotonic_channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  // Background sync channel (stub on Windows — Dart Timer.periodic handles
  // scheduling; native task scheduling would require installer-level
  // permissions this plugin does not hold).
  auto background_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "trusted_time/background",
          &flutter::StandardMethodCodec::GetInstance());
  background_channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

// Constructor / destructor
TrustedTimePlugin::TrustedTimePlugin(flutter::PluginRegistrarWindows *registrar)
    : registrar_(registrar) {}

TrustedTimePlugin::~TrustedTimePlugin() = default;

void TrustedTimePlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() == "getPlatformVersion") {
    result->Success(flutter::EncodableValue(std::string("Windows 10+")));
  } else if (method_call.method_name() == "getUptimeMs") {
    // GetTickCount64 returns milliseconds since system boot and is immune to
    // user-level system-clock manipulation. Available on Vista+; Flutter itself
    // requires Windows 10 build 1809, so no version guard is needed.
    int64_t uptimeMs = static_cast<int64_t>(GetTickCount64());
    result->Success(flutter::EncodableValue(uptimeMs));
  } else if (method_call.method_name() == "getBootId") {
    // The kernel increments this counter on every boot (the same value the
    // Event Log stamps into records). Unlike a boot instant derived from
    // wall-clock minus uptime, it cannot be forged by manipulating the
    // system clock. Null on read failure — the Dart side fails closed by
    // treating anchors without a matching boot ID as rebooted.
    // RRF_SUBKEY_WOW6464KEY pins the read to the 64-bit registry view so a
    // 32-bit build on 64-bit Windows sees the same kernel counter. HKLM\SYSTEM
    // sits in the shared (non-redirected) portion of the registry, but the
    // explicit flag removes any dependence on the WOW64 redirection table.
    DWORD boot_id = 0;
    DWORD size = sizeof(boot_id);
    LSTATUS status = RegGetValueW(
        HKEY_LOCAL_MACHINE,
        L"SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory "
        L"Management\\PrefetchParameters",
        L"BootId", RRF_RT_REG_DWORD | RRF_SUBKEY_WOW6464KEY, nullptr, &boot_id,
        &size);
    if (status == ERROR_SUCCESS) {
      result->Success(
          flutter::EncodableValue("bootid:" + std::to_string(boot_id)));
    } else {
      // Explicit null EncodableValue: the zero-arg Success() overload is
      // not consistently available across Flutter Windows wrapper
      // versions.
      result->Success(flutter::EncodableValue());
    }
  } else if (method_call.method_name() == "enableBackgroundSync") {
    // Background sync is stubbed on Windows. The Dart layer already provides
    // a Timer.periodic fallback for desktop platforms where the app runs
    // persistently. Returning true signals the Dart side that no error
    // occurred.
    result->Success(flutter::EncodableValue(true));
  } else {
    result->NotImplemented();
  }
}

} // namespace trusted_time