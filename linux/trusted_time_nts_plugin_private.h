#include <flutter_linux/flutter_linux.h>

#include "include/trusted_time_nts/trusted_time_nts_plugin.h"

// This file exposes some plugin internals for unit testing. See
// https://github.com/flutter/flutter/issues/88724 for current limitations
// in the unit-testable API.

// Handles the getPlatformVersion method call.
FlMethodResponse *get_platform_version();