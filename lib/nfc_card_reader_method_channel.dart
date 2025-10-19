import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'nfc_card_reader_platform_interface.dart';

/// An implementation of [NfcCardReaderPlatform] that uses method channels.
class MethodChannelNfcCardReader extends NfcCardReaderPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('nfc_card_reader');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
