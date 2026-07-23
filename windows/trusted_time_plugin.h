#ifndef FLUTTER_PLUGIN_TRUSTED_TIME_PLUGIN_H_
#define FLUTTER_PLUGIN_TRUSTED_TIME_PLUGIN_H_

// Any translation unit that includes this header needs the Win32 types used
// by the method handlers, all of which are defined in windows.h. Relying on
// the includer to have already pulled in windows.h is fragile and breaks
// unity builds.
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace trusted_time {

class TrustedTimePlugin : public flutter::Plugin {
public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  explicit TrustedTimePlugin(flutter::PluginRegistrarWindows *registrar);

  virtual ~TrustedTimePlugin();

  // Disallow copy and assign.
  TrustedTimePlugin(const TrustedTimePlugin &) = delete;
  TrustedTimePlugin &operator=(const TrustedTimePlugin &) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

private:
  flutter::PluginRegistrarWindows *registrar_ = nullptr;
};

} // namespace trusted_time

#endif // FLUTTER_PLUGIN_TRUSTED_TIME_PLUGIN_H_