import 'package:flutter/material.dart';
import 'package:nfc_card_reader/nfc_card_reader.dart';
import 'dart:async';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NFC Card Reader',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const NfcReaderPage(),
    );
  }
}

class NfcReaderPage extends StatefulWidget {
  const NfcReaderPage({super.key});

  @override
  State<NfcReaderPage> createState() => _NfcReaderPageState();
}

class _NfcReaderPageState extends State<NfcReaderPage> {
  bool _isNfcAvailable = false;
  bool _isNfcEnabled = false;
  bool _isReading = false;
  CardData? _cardData;
  String? _errorMessage;

  StreamSubscription? _cardSubscription;
  StreamSubscription? _errorSubscription;

  @override
  void initState() {
    super.initState();
    _checkNfcStatus();
    // Setup listeners immediately
    _setupListeners();
  }

  @override
  void dispose() {
    _cardSubscription?.cancel();
    _errorSubscription?.cancel();
    if (_isReading) {
      NfcCardReader.stopReading();
    }
    super.dispose();
  }

  Future<void> _checkNfcStatus() async {
    final available = await NfcCardReader.isNfcAvailable;
    final enabled = await NfcCardReader.isNfcEnabled;

    setState(() {
      _isNfcAvailable = available;
      _isNfcEnabled = enabled;
    });
  }

  void _setupListeners() {
    print("Setting up NFC listeners...");

    _cardSubscription = NfcCardReader.cardStream.listen(
          (cardData) {
        print("========== CARD DATA RECEIVED ==========");
        print("Card Number: ${cardData.cardNumber}");
        print("Cardholder Name: ${cardData.cardholderName}");
        print("Expiration Date: ${cardData.expirationDate}");
        print("======================================");

        setState(() {
          _cardData = cardData;
          _errorMessage = null;
        });
      },
      onError: (error) {
        print("Stream error: $error");
        setState(() {
          _errorMessage = error.toString();
        });
      },
      onDone: () {
        print("Card stream closed");
      },
    );

    _errorSubscription = NfcCardReader.errorStream.listen(
          (error) {
        print("========== ERROR RECEIVED ==========");
        print("Error: $error");
        print("====================================");

        setState(() {
          _errorMessage = error;
          _cardData = null;
        });
      },
      onError: (error) {
        print("Error stream error: $error");
      },
    );

    print("NFC listeners setup complete");
  }

  Future<void> _toggleReading() async {
    if (!_isNfcAvailable) {
      setState(() {
        _errorMessage = 'NFC not available on this device';
      });
      return;
    }

    if (!_isNfcEnabled) {
      final shouldOpen = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('NFC Disabled'),
          content: const Text('NFC is disabled. Would you like to open NFC settings?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );

      if (shouldOpen == true) {
        await NfcCardReader.openNfcSettings();
      }
      return;
    }

    if (_isReading) {
      print("Stopping NFC reading...");
      await NfcCardReader.stopReading();
      setState(() {
        _isReading = false;
        _cardData = null;
        _errorMessage = null;
      });
    } else {
      print("Starting NFC reading...");
      await NfcCardReader.startReading();
      setState(() {
        _isReading = true;
        _cardData = null;
        _errorMessage = null;
      });
      print("NFC reading started - ready to scan");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('NFC Card Reader'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildStatusChip('NFC Available', _isNfcAvailable),
              const SizedBox(height: 8),
              _buildStatusChip('NFC Enabled', _isNfcEnabled),
              const SizedBox(height: 32),

              if (_errorMessage != null)
                _buildErrorCard()
              else if (_cardData != null)
                _buildCardDataCard()
              else
                _buildReadyState(),
              const SizedBox(height: 32),

              ElevatedButton.icon(
                onPressed: _toggleReading,
                icon: Icon(_isReading ? Icons.stop : Icons.nfc),
                label: Text(_isReading ? 'Stop Reading' : 'Start Reading'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 16,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusChip(String label, bool isActive) {
    return Chip(
      avatar: Icon(
        isActive ? Icons.check_circle : Icons.cancel,
        color: isActive ? Colors.green : Colors.red,
      ),
      label: Text(label),
    );
  }

  Widget _buildErrorCard() {
    return Card(
      color: Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: const TextStyle(
                color: Colors.red,
                fontSize: 16,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCardDataCard() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Card Number:',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _maskCardNumber(_cardData!.cardNumber),
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Expiration:',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _cardData!.expirationDate,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (_cardData!.cardholderName != null) ...[
              const SizedBox(height: 16),
              const Text(
                'Cardholder:',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _cardData!.cardholderName!,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildReadyState() {
    return Column(
      children: [
        Icon(
          Icons.nfc,
          size: 64,
          color: _isReading ? Colors.blue : Colors.grey,
        ),
        const SizedBox(height: 16),
        Text(
          _isReading ? 'Tap a card to read...' : 'Ready to scan',
          style: TextStyle(
            fontSize: 18,
            color: _isReading ? Colors.blue : Colors.grey,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  String _maskCardNumber(String cardNumber) {
    final digits = cardNumber.replaceAll(' ', '');
    if (digits.length >= 4) {
      return cardNumber;
    }
    return cardNumber;
  }
}