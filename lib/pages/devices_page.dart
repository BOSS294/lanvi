/*
 * Purpose: Show nearby Lanvi clients and locally remembered devices.
 * Integration: Add DevicesPage to the HomePage navigation stack.
 * Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
 * Changelog: Repairs widget-tree syntax, adds safer async/error handling,
 *            real address copying, and bounds-safe discovery matching.
 */

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../core/style/app_radius.dart';
import '../core/style/app_spacing.dart';
import '../services/lanvi_connection_service.dart';
import '../services/lanvi_device_discovery_service.dart';
import '../services/lanvi_device_registry_service.dart';
import 'lanvi_pairing_page.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  final LanviDeviceDiscoveryService _discovery =
      LanviDeviceDiscoveryService.instance;
  final LanviDeviceRegistryService _registry =
      LanviDeviceRegistryService.instance;

  List<LanviKnownDevice> _knownDevices = const <LanviKnownDevice>[];
  LanviPairing? _currentPairing;
  bool _loadingKnown = true;
  bool _refreshing = false;
  bool _showOffline = true;
  String? _localError;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _discovery.start();
    } catch (error) {
      if (mounted) {
        setState(() => _localError = 'Could not start local discovery: $error');
      }
    }
    await _loadSavedDevices();
  }

  Future<void> _loadSavedDevices() async {
    try {
      final known = await _registry.loadKnownDevices();
      final pairing = await LanviConnectionService.instance.loadPairing();
      if (!mounted) return;

      setState(() {
        _knownDevices = known;
        _currentPairing = pairing;
        _loadingKnown = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingKnown = false;
        _localError = 'Could not load saved devices: $error';
      });
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _localError = null;
    });

    try {
      await _discovery.refreshDiscovery();
      await _loadSavedDevices();
      if (mounted && _localError == null) {
        _showMessage('Device discovery refreshed.');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _localError = 'Could not refresh discovery: $error');
        _showMessage('Could not refresh devices. Check your local network.');
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _pairViaQr() async {
    try {
      await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => const LanviPairingPage(),
        ),
      );
      await _loadSavedDevices();
    } catch (error) {
      if (mounted) _showMessage('Could not open pairing: $error');
    }
  }

  Future<void> _renameDevice({
    required String deviceId,
    required String currentName,
    required bool isThisDevice,
  }) async {
    final controller = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isThisDevice ? 'Rename this device' : 'Rename device locally'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 64,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Device name',
            hintText: 'e.g. Mayank phone',
          ),
          onSubmitted: (value) =>
              Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Save name'),
          ),
        ],
      ),
    );
    controller.dispose();

    final cleanedName = newName?.trim();
    if (cleanedName == null || cleanedName.isEmpty) return;

    try {
      if (isThisDevice) {
        await _discovery.renameThisDevice(cleanedName);
      } else {
        await _registry.renameDevice(deviceId, cleanedName);
      }
      await _loadSavedDevices();
      if (mounted) _showMessage('Device name updated.');
    } catch (error) {
      if (mounted) _showMessage('Could not rename device: $error');
    }
  }

  Future<void> _forgetDevice(LanviKnownDevice device) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Forget ${device.displayName}?'),
        content: const Text(
          'This removes its saved name and local remembered record. If the '
          'device is still nearby, it may appear again as discovered. A fresh '
          'QR scan is required to pair again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Forget device'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      final pairing = await LanviConnectionService.instance.loadPairing();
      final isCurrent = pairing != null &&
          (pairing.deviceId == device.deviceId ||
              (pairing.host == device.address && pairing.port == device.port));

      if (isCurrent) {
        await LanviConnectionService.instance.clearPairing();
      }
      await _registry.forgetDevice(device.deviceId);
      await _loadSavedDevices();

      if (mounted) {
        _showMessage(
          isCurrent
              ? 'Device forgotten and current pairing cleared.'
              : 'Device removed from the local remembered list.',
        );
      }
    } catch (error) {
      if (mounted) _showMessage('Could not forget device: $error');
    }
  }

  Future<void> _copyAddress(String address) async {
    try {
      await Clipboard.setData(ClipboardData(text: address));
      _showMessage('Device address copied.');
    } catch (error) {
      if (mounted) _showMessage('Could not copy address: $error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  LanviKnownDevice? _knownFor(LanviDiscoveredDevice discovered) {
    for (final known in _knownDevices) {
      final sameId = known.deviceId == discovered.deviceId;
      final sameDesktopAddress = known.deviceType == 'desktop' &&
          discovered.deviceType == 'desktop' &&
          known.address.isNotEmpty &&
          discovered.addresses.contains(known.address);
      if (sameId || sameDesktopAddress) return known;
    }
    return null;
  }

  bool _isKnownDeviceOnline(
    LanviKnownDevice known,
    List<LanviDiscoveredDevice> discovered,
  ) {
    for (final device in discovered) {
      final sameId = device.deviceId == known.deviceId;
      final sameAddress = known.address.isNotEmpty &&
          device.addresses.contains(known.address);
      if (sameId || sameAddress) return device.isOnline;
    }
    return false;
  }

  bool _isCurrentPairing(LanviKnownDevice device) {
    final pairing = _currentPairing;
    if (pairing == null) return false;
    return pairing.deviceId == device.deviceId ||
        (pairing.host == device.address && pairing.port == device.port);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Devices'),
        actions: [
          IconButton(
            tooltip: 'Refresh nearby devices',
            onPressed: _refreshing ? null : _refresh,
            icon: AnimatedRotation(
              turns: _refreshing ? 1 : 0,
              duration: const Duration(milliseconds: 500),
              child: Icon(
                PhosphorIcons.arrowsClockwise(PhosphorIconsStyle.light),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator.adaptive(
          onRefresh: _refresh,
          child: AnimatedBuilder(
            animation: _discovery,
            builder: (context, _) {
              final discovered = List<LanviDiscoveredDevice>.of(
                _discovery.devices,
              );
              final visibleDevices = _showOffline
                  ? discovered
                  : discovered
                      .where((device) => device.isOnline)
                      .toList(growable: false);

              return ListView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.pageHorizontal,
                  AppSpacing.lg,
                  AppSpacing.pageHorizontal,
                  AppSpacing.xl,
                ),
                children: [
                  Text(
                    'Your local network',
                    style: textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Lanvi looks for compatible devices nearby. Discovery '
                    'never grants transfer permission; a device must still '
                    'be paired explicitly.',
                    style: textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _LocalDeviceCard(
                    name: _discovery.ownDeviceName,
                    deviceId: _discovery.ownDeviceId ?? 'initializing',
                    isAdvertising: _discovery.isAdvertising,
                    isScanning: _discovery.isScanning,
                    onRename: () => _renameDevice(
                      deviceId: _discovery.ownDeviceId ?? 'local',
                      currentName: _discovery.ownDeviceName,
                      isThisDevice: true,
                    ),
                  ),
                  if (_localError != null || _discovery.errorMessage != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    _NoticeCard(
                      icon: PhosphorIcons.warningCircle(
                        PhosphorIconsStyle.light,
                      ),
                      title: 'Discovery needs attention',
                      message: _localError ?? _discovery.errorMessage!,
                      actionLabel: 'Try again',
                      onAction: _refresh,
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Nearby devices',
                          style: textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        '${visibleDevices.length}',
                        style: textTheme.labelLarge?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (visibleDevices.isEmpty)
                    _NoticeCard(
                      icon: PhosphorIcons.radio(PhosphorIconsStyle.light),
                      title: _discovery.isScanning
                          ? 'Searching your local network'
                          : 'No devices found yet',
                      message: 'Keep Lanvi running on the other device and '
                          'make sure both devices can communicate on the same '
                          'LAN. Guest Wi-Fi and client isolation can block discovery.',
                      actionLabel: 'Scan again',
                      onAction: _refresh,
                    )
                  else
                    ...visibleDevices.map((device) {
                      final known = _knownFor(device);
                      final displayName = known?.displayName ?? device.name;
                      return Padding(
                        key: ValueKey<String>('nearby-${device.deviceId}'),
                        padding: const EdgeInsets.only(
                          bottom: AppSpacing.sm,
                        ),
                        child: _DiscoveredDeviceCard(
                          device: device,
                          displayName: displayName,
                          isKnown: known != null,
                          onPair: device.isDesktop ? _pairViaQr : null,
                          onRename: () => _renameDevice(
                            deviceId: device.deviceId,
                            currentName: displayName,
                            isThisDevice: false,
                          ),
                          onForget: known == null
                              ? null
                              : () => _forgetDevice(known),
                          onCopyAddress: device.primaryAddress.isEmpty
                              ? null
                              : () => _copyAddress(
                                    '${device.primaryAddress}:${device.port}',
                                  ),
                        ),
                      );
                    }),
                  const SizedBox(height: AppSpacing.xl),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Remembered devices',
                          style: textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        '${_knownDevices.length}',
                        style: textTheme.labelLarge?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (_loadingKnown)
                    const Padding(
                      padding: EdgeInsets.all(AppSpacing.lg),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_knownDevices.isEmpty)
                    _NoticeCard(
                      icon: PhosphorIcons.bookmarkSimple(
                        PhosphorIconsStyle.light,
                      ),
                      title: 'No paired devices yet',
                      message: 'Scan the current QR code displayed by the PC '
                          'receiver. Lanvi will remember the device name and '
                          'address locally.',
                      actionLabel: 'Scan pairing QR',
                      onAction: _pairViaQr,
                    )
                  else
                    ..._knownDevices.map((device) {
                      final online = _isKnownDeviceOnline(device, discovered);
                      return Padding(
                        key: ValueKey<String>('known-${device.deviceId}'),
                        padding: const EdgeInsets.only(
                          bottom: AppSpacing.sm,
                        ),
                        child: _KnownDeviceCard(
                          device: device,
                          isCurrent: _isCurrentPairing(device),
                          isOnline: online,
                          pairingExpired: device.pairingMayBeExpired,
                          onRename: () => _renameDevice(
                            deviceId: device.deviceId,
                            currentName: device.displayName,
                            isThisDevice: false,
                          ),
                          onForget: () => _forgetDevice(device),
                          onRefreshPairing: _pairViaQr,
                        ),
                      );
                    }),
                  const SizedBox(height: AppSpacing.md),
                  SwitchListTile.adaptive(
                    value: _showOffline,
                    onChanged: (value) => setState(() => _showOffline = value),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show offline devices'),
                    subtitle: const Text(
                      'Recently discovered devices remain visible briefly '
                      'after they disappear.',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Discovery is local mDNS. It does not use cloud services, '
                    'and it cannot cross Wi-Fi client isolation or networks '
                    'that block multicast. Device labels are local to this installation.',
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _LocalDeviceCard extends StatelessWidget {
  const _LocalDeviceCard({
    required this.name,
    required this.deviceId,
    required this.isAdvertising,
    required this.isScanning,
    required this.onRename,
  });

  final String name;
  final String deviceId;
  final bool isAdvertising;
  final bool isScanning;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final status = isAdvertising
        ? (isScanning
            ? 'Discoverable · scanning nearby'
            : 'Discoverable on local network')
        : 'Starting discovery…';

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withOpacity(0.45),
        borderRadius: AppRadius.large,
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: AppRadius.medium,
            ),
            child: Icon(
              PhosphorIcons.deviceMobile(PhosphorIconsStyle.light),
              color: colors.onPrimaryContainer,
              size: 25,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This device',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  status,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'ID · ${_shortDeviceId(deviceId)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Rename this device',
            onPressed: onRename,
            icon: Icon(PhosphorIcons.pencilSimple(PhosphorIconsStyle.light)),
          ),
        ],
      ),
    );
  }
}

class _DiscoveredDeviceCard extends StatelessWidget {
  const _DiscoveredDeviceCard({
    required this.device,
    required this.displayName,
    required this.isKnown,
    required this.onPair,
    required this.onRename,
    required this.onForget,
    required this.onCopyAddress,
  });

  final LanviDiscoveredDevice device;
  final String displayName;
  final bool isKnown;
  final VoidCallback? onPair;
  final VoidCallback onRename;
  final VoidCallback? onForget;
  final VoidCallback? onCopyAddress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final iconData = device.isDesktop
        ? PhosphorIcons.monitor(PhosphorIconsStyle.light)
        : PhosphorIcons.deviceMobile(PhosphorIconsStyle.light);
    final status = device.isOnline
        ? 'Online'
        : 'Last seen ${_timeAgo(device.lastSeenAt)}';

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppRadius.large,
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: AppRadius.medium,
                ),
                child: Icon(iconData, color: colors.primary, size: 23),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${device.deviceType.toUpperCase()} · $status',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: device.isOnline
                            ? colors.primary
                            : colors.onSurfaceVariant,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Device actions',
                onSelected: (value) {
                  if (value == 'rename') {
                    onRename();
                  } else if (value == 'forget') {
                    onForget?.call();
                  } else if (value == 'copy') {
                    onCopyAddress?.call();
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem<String>(
                    value: 'rename',
                    child: Text('Rename locally'),
                  ),
                  if (onCopyAddress != null)
                    const PopupMenuItem<String>(
                      value: 'copy',
                      child: Text('Copy address'),
                    ),
                  if (onForget != null)
                    const PopupMenuItem<String>(
                      value: 'forget',
                      child: Text('Forget local record'),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            device.addresses.isEmpty
                ? 'Address not resolved'
                : device.addresses.join('  ·  '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Flexible(
                child: _StatusPill(
                  label: isKnown ? 'Remembered' : 'Discovered · not paired',
                  color: isKnown ? colors.primary : colors.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              if (onPair != null)
                TextButton.icon(
                  onPressed: onPair,
                  icon: Icon(
                    PhosphorIcons.qrCode(PhosphorIconsStyle.light),
                    size: 18,
                  ),
                  label: const Text('Pair via QR'),
                )
              else
                Text(
                  'Discovery only',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          if (!device.isDesktop)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                'This device is visible on the LAN. PC-to-phone receiving is not enabled yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _KnownDeviceCard extends StatelessWidget {
  const _KnownDeviceCard({
    required this.device,
    required this.isCurrent,
    required this.isOnline,
    required this.pairingExpired,
    required this.onRename,
    required this.onForget,
    required this.onRefreshPairing,
  });

  final LanviKnownDevice device;
  final bool isCurrent;
  final bool isOnline;
  final bool pairingExpired;
  final VoidCallback onRename;
  final VoidCallback onForget;
  final VoidCallback onRefreshPairing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final status = !isOnline
        ? 'Offline'
        : pairingExpired
            ? 'Visible · rescan QR'
            : isCurrent
                ? 'Current pairing'
                : 'Remembered';

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppRadius.large,
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: AppRadius.medium,
            ),
            child: Icon(
              PhosphorIcons.monitor(PhosphorIconsStyle.light),
              color: colors.primary,
              size: 23,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${device.address}:${device.port}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                _StatusPill(
                  label: status,
                  color: isOnline ? colors.primary : colors.onSurfaceVariant,
                ),
                if (device.pairingExpiresAt != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'QR token expires ${_formatDateTime(device.pairingExpiresAt!.toLocal())}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    TextButton.icon(
                      onPressed: onRename,
                      icon: Icon(
                        PhosphorIcons.pencilSimple(PhosphorIconsStyle.light),
                        size: 17,
                      ),
                      label: const Text('Rename'),
                    ),
                    TextButton.icon(
                      onPressed: onRefreshPairing,
                      icon: Icon(
                        PhosphorIcons.qrCode(PhosphorIconsStyle.light),
                        size: 17,
                      ),
                      label: const Text('Scan fresh QR'),
                    ),
                    TextButton.icon(
                      onPressed: onForget,
                      icon: Icon(
                        PhosphorIcons.trash(PhosphorIconsStyle.light),
                        size: 17,
                      ),
                      label: const Text('Forget'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withOpacity(0.35),
        borderRadius: AppRadius.large,
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 24, color: colors.primary),
          const SizedBox(height: AppSpacing.sm),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onAction,
              child: Text(actionLabel),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.09),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String _shortDeviceId(String deviceId) {
  final trimmed = deviceId.trim();
  if (trimmed.length <= 12) return trimmed;
  return '${trimmed.substring(0, 6)}…${trimmed.substring(trimmed.length - 4)}';
}

String _formatDateTime(DateTime date) {
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '$year-$month-$day $hour:$minute';
}

String _timeAgo(DateTime date) {
  final difference = DateTime.now().difference(date);
  if (difference.isNegative || difference.inSeconds < 60) return 'just now';
  if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
  if (difference.inHours < 24) return '${difference.inHours}h ago';
  return '${difference.inDays}d ago';
}
