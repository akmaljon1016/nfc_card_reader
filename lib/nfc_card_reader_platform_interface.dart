import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'nfc_card_reader_method_channel.dart';

abstract class NfcCardReaderPlatform extends PlatformInterface {
  /// Constructs a NfcCardReaderPlatform.
  NfcCardReaderPlatform() : super(token: _token);

  static final Object _token = Object();

  static NfcCardReaderPlatform _instance = MethodChannelNfcCardReader();

  /// The default instance of [NfcCardReaderPlatform] to use.
  ///
  /// Defaults to [MethodChannelNfcCardReader].
  static NfcCardReaderPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [NfcCardReaderPlatform] when
  /// they register themselves.
  static set instance(NfcCardReaderPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
