#include "include/trusted_time_nts/trusted_time_nts_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "trusted_time_nts_plugin.h"

void TrustedTimeNtsPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  trusted_time_nts::TrustedTimeNtsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}