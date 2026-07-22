/// Barrel for the built-in network time sources, resolving the
/// platform-conditional NTP and NTS implementations.
library;

export 'ntp_source_stub.dart' if (dart.library.io) 'ntp_source_io.dart';
export 'nts_source_stub.dart' if (dart.library.io) 'nts_source.dart';
