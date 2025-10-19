import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_card_reader/nfc_card_reader.dart';
import 'package:nfc_card_reader/nfc_card_reader_platform_interface.dart';
import 'package:nfc_card_reader/nfc_card_reader_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockNfcCardReaderPlatform
    with MockPlatformInterfaceMixin
    implements NfcCardReaderPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final NfcCardReaderPlatform initialPlatform = NfcCardReaderPlatform.instance;

  test('$MethodChannelNfcCardReader is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelNfcCardReader>());
  });

  test('getPlatformVersion', () async {
    NfcCardReader nfcCardReaderPlugin = NfcCardReader();
    MockNfcCardReaderPlatform fakePlatform = MockNfcCardReaderPlatform();
    NfcCardReaderPlatform.instance = fakePlatform;

    expect(await nfcCardReaderPlugin.getPlatformVersion(), '42');
  });
}
