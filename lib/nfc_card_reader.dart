import 'dart:async';
import 'package:flutter/services.dart';

/// Card data model
class CardData {
  final String cardNumber;
  final String expirationDate;
  final String? cardholderName;

  CardData({
    required this.cardNumber,
    required this.expirationDate,
    this.cardholderName,
  });

  factory CardData.fromMap(Map<String, dynamic> map) {
    return CardData(
      cardNumber: map['cardNumber'] as String,
      expirationDate: map['expirationDate'] as String,
      cardholderName: map['cardholderName'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'cardNumber': cardNumber,
      'expirationDate': expirationDate,
      'cardholderName': cardholderName,
    };
  }

  @override
  String toString() {
    return 'CardData(cardNumber: $cardNumber, expirationDate: $expirationDate, cardholderName: $cardholderName)';
  }
}

/// NFC Card Reader Plugin
class NfcCardReader {
  static const MethodChannel _channel = MethodChannel('nfc_card_reader');
  static const EventChannel _eventChannel = EventChannel('nfc_card_reader/events');

  // Cache the broadcast stream to allow multiple listeners
  static Stream<Map>? _cachedStream;

  /// Internal event stream that caches and broadcasts events
  static Stream<Map> get _eventStream {
    if (_cachedStream == null) {
      _cachedStream = _eventChannel
          .receiveBroadcastStream()
          .map((event) {
        print("------------RAW EVENT: ${event.toString()}----------------");
        return event as Map;
      })
          .asBroadcastStream(); // Allow multiple listeners
    }
    return _cachedStream!;
  }

  /// Stream of card data events
  static Stream<CardData> get cardStream {
    return _eventStream.where((event) {
      final isCard = event['type'] == 'card';
      if (isCard) {
        print("------------CARD EVENT DETECTED----------------");
      }
      return isCard;
    }).map((event) {
      print("------------MAPPING CARD DATA----------------");
      final data = Map<String, dynamic>.from(event['data']);
      return CardData.fromMap(data);
    });
  }

  /// Stream of error messages
  static Stream<String> get errorStream {
    return _eventStream.where((event) {
      final isError = event['type'] == 'error';
      if (isError) {
        print("------------ERROR EVENT DETECTED----------------");
      }
      return isError;
    }).map((event) {
      return event['message'] as String;
    });
  }

  /// Check if NFC is available on the device
  static Future<bool> get isNfcAvailable async {
    try {
      final bool available = await _channel.invokeMethod('isNfcAvailable');
      return available;
    } catch (e) {
      print('Error checking NFC availability: $e');
      return false;
    }
  }

  /// Check if NFC is enabled
  static Future<bool> get isNfcEnabled async {
    try {
      final bool enabled = await _channel.invokeMethod('isNfcEnabled');
      return enabled;
    } catch (e) {
      print('Error checking NFC enabled status: $e');
      return false;
    }
  }

  /// Start listening for NFC cards
  static Future<void> startReading() async {
    try {
      print('Starting NFC reading...');
      await _channel.invokeMethod('startReading');
      print('NFC reading started successfully');
    } on PlatformException catch (e) {
      print('PlatformException starting NFC: ${e.message}');
      throw Exception('Failed to start NFC reading: ${e.message}');
    }
  }

  /// Stop listening for NFC cards
  static Future<void> stopReading() async {
    try {
      print('Stopping NFC reading...');
      await _channel.invokeMethod('stopReading');
      print('NFC reading stopped successfully');
    } on PlatformException catch (e) {
      print('PlatformException stopping NFC: ${e.message}');
      throw Exception('Failed to stop NFC reading: ${e.message}');
    }
  }

  /// Open NFC settings
  static Future<void> openNfcSettings() async {
    try {
      await _channel.invokeMethod('openNfcSettings');
    } on PlatformException catch (e) {
      print('PlatformException opening NFC settings: ${e.message}');
      throw Exception('Failed to open NFC settings: ${e.message}');
    }
  }

  /// Reset the cached stream (useful for testing or reinitialization)
  static void resetStream() {
    _cachedStream = null;
  }
}