import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// The production [rootBundle]-backed asset loader for `AsnResolver`.
///
/// Lives apart from `asn_resolver.dart` so the resolver itself stays
/// Flutter-free and usable on the standalone Dart VM (the
/// `bin/ntp_cli.dart` probe tool supplies a `dart:io` file loader
/// instead); Flutter callers pair the two via `NtpSource`'s shared
/// resolver.
Future<Uint8List> rootBundleAssetLoader(String key) async {
  final data = await rootBundle.load(key);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
