// Purpose: Scans the Chrome receiver's local QR, validates the LAN address, checks the bridge, and saves pairing locally.
// How to use: Push LanviPairingPage and await a true result when pairing succeeds.
// Project: Lanvi | Release: 1.2.1 | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: 1.2.1 — replaces the temporary browser test page with native Flutter QR pairing.

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/style/app_radius.dart';
import '../core/style/app_spacing.dart';
import '../services/lanvi_connection_service.dart';

class LanviPairingPage extends StatefulWidget {
  const LanviPairingPage({super.key});

  @override
  State<LanviPairingPage> createState() => _LanviPairingPageState();
}

class _LanviPairingPageState extends State<LanviPairingPage> {
  final TextEditingController _manualQrController = TextEditingController();
  bool _isProcessing = false;
  String? _message;
  bool _messageIsError = true;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_isProcessing) return;
    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue != null && rawValue.trim().isNotEmpty) {
        await _pairFromQr(rawValue);
        return;
      }
    }
  }

  Future<void> _pairFromQr(String rawValue) async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
      _message = 'Checking your PC on the local network…';
      _messageIsError = false;
    });

    try {
      final pairing = LanviPairing.fromQr(rawValue);
      final isOnline = await LanviConnectionService.instance.checkHealth(pairing);
      if (!isOnline) {
        throw const FormatException(
          'Lanvi could not reach the PC. Check that the bridge is running, both devices share a reachable Wi-Fi network, and Windows Firewall allows the private-network connection.',
        );
      }

      await LanviConnectionService.instance.savePairing(pairing);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = error.toString().replaceFirst('FormatException: ', '');
        _messageIsError = true;
        _isProcessing = false;
      });
    }
  }

  @override
  void dispose() {
    _manualQrController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect your PC'),
        leading: IconButton(
          tooltip: 'Back',
          onPressed: _isProcessing ? null : () => Navigator.of(context).maybePop(false),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
          children: [
            Text(
              'Pair with Lanvi Receiver',
              style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Open the Lanvi Receiver dashboard in Chrome on your PC and scan its current QR code. The code contains your PC’s local address and a temporary pairing token.',
              style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
            ),
            const SizedBox(height: AppSpacing.lg),
            Container(
              height: 320,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: AppRadius.large,
                border: Border.all(color: scheme.outlineVariant),
                color: Colors.black,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MobileScanner(
                    onDetect: _onDetect,
                    errorBuilder: (context, error) => Container(
                      color: scheme.surface,
                      padding: const EdgeInsets.all(AppSpacing.md),
                      alignment: Alignment.center,
                      child: Text(
                        'Camera is unavailable. Check Lanvi’s camera permission and try again.\n\n${error.errorCode.name}',
                        textAlign: TextAlign.center,
                        style: textTheme.bodyMedium,
                      ),
                    ),
                  ),
                  IgnorePointer(
                    child: Center(
                      child: Container(
                        width: 232,
                        height: 232,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 3),
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                    ),
                  ),
                  if (_isProcessing)
                    Container(
                      color: Colors.black.withOpacity(0.62),
                      alignment: Alignment.center,
                      child: const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: Colors.white),
                          SizedBox(height: 16),
                          Text('Connecting to PC…', style: TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (_message != null) ...[
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: _messageIsError ? scheme.errorContainer : scheme.surfaceContainerHighest,
                  borderRadius: AppRadius.medium,
                ),
                child: Text(
                  _message!,
                  style: textTheme.bodySmall?.copyWith(
                    color: _messageIsError ? scheme.onErrorContainer : scheme.onSurface,
                    height: 1.45,
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Text('Having trouble scanning?', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Paste the current QR link copied from the PC if your camera is unavailable.',
              style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _manualQrController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Lanvi pairing URL',
                hintText: 'http://192.168.x.x:8787/mobile-test?token=…',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            FilledButton.icon(
              onPressed: _isProcessing || _manualQrController.text.trim().isEmpty
                  ? null
                  : () => _pairFromQr(_manualQrController.text),
              icon: const Icon(Icons.link),
              label: const Text('Connect using URL'),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Development prototype: this connection uses HTTP on your local network. Use only your trusted private Wi-Fi; do not transfer sensitive files until authenticated encryption is implemented.',
              style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}
