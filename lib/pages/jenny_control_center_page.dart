// Purpose: Jenny's local control center for AI, voice, SMS/call policies, emergency alerts and activity history.
// Integration: Add JennyControlCenterPage to Lanvi Settings or Home navigation.
// Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: Provides per-device model/key setup, saved-contact-only AI controls and explicit Android permissions.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/style/app_radius.dart';
import '../core/style/app_spacing.dart';
import '../services/jenny/jenny_activity_service.dart';
import '../services/jenny/jenny_groq_service.dart';
import '../services/jenny/jenny_local_policy.dart';
import '../services/jenny/jenny_native_bridge.dart';
import '../services/jenny/jenny_settings_service.dart';
import '../services/jenny/jenny_voice_service.dart';

class JennyControlCenterPage extends StatefulWidget {
  const JennyControlCenterPage({super.key});

  @override
  State<JennyControlCenterPage> createState() => _JennyControlCenterPageState();
}

class _JennyControlCenterPageState extends State<JennyControlCenterPage> with SingleTickerProviderStateMixin {
  final JennySettingsService _settings = JennySettingsService.instance;
  final JennyNativeBridge _native = JennyNativeBridge.instance;
  final JennyActivityService _activity = JennyActivityService.instance;
  final JennyGroqService _groq = JennyGroqService.instance;
  final JennyVoiceService _voice = JennyVoiceService.instance;

  late final TabController _tabs;
  final TextEditingController _groqKey = TextEditingController();
  final TextEditingController _sarvamKey = TextEditingController();
  final TextEditingController _context = TextEditingController();
  final TextEditingController _busyMessage = TextEditingController();
  final TextEditingController _sleepMessage = TextEditingController();
  final TextEditingController _missedMessage = TextEditingController();
  final TextEditingController _chatInput = TextEditingController();
  final ScrollController _chatScroll = ScrollController();

  List<JennyModelChoice> _models = const <JennyModelChoice>[
    JennyModelChoice(id: 'openai/gpt-oss-20b', description: 'Recommended start: efficient general assistant for concise replies.'),
    JennyModelChoice(id: 'openai/gpt-oss-120b', description: 'Higher-capability reasoning; check account access and usage limits.'),
    JennyModelChoice(id: 'llama-3.1-8b-instant', description: 'Low-latency assistant model when available to your Groq account.'),
    JennyModelChoice(id: 'llama-3.3-70b-versatile', description: 'General assistant model when available to your Groq account.'),
  ];
  List<Map<String, Object?>> _contacts = <Map<String, Object?>>[];
  List<Map<String, Object?>> _sms = <Map<String, Object?>>[];
  List<Map<String, Object?>> _calls = <Map<String, Object?>>[];
  List<Map<String, String>> _chat = <Map<String, String>>[];
  List<String> _eventLog = <String>[];
  bool _loading = true;
  bool _busy = false;
  bool _modelsLoading = false;
  bool _hasGroqKey = false;
  bool _hasSarvamKey = false;
  bool _callRole = false;
  bool _overlayPermission = false;
  bool _fullScreenIntentPermission = false;
  Timer? _wakeUiTimer;
  bool _showKeys = false;
  bool _saying = false;
  String? _statusMessage;
  bool _statusIsError = false;

  static const String _chatHistoryKey = 'lanvi.jenny.chat_history.local';
  static const String _eventHistoryKey = 'lanvi.jenny.events.local';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _settings.load();
      _context.text = _settings.get<String>('approvedContext');
      _busyMessage.text = _settings.get<String>('busyMessage');
      _sleepMessage.text = _settings.get<String>('sleepMessage');
      _missedMessage.text = _settings.get<String>('missedCallMessage');
      _hasGroqKey = await _native.hasSecret('groq');
      _hasSarvamKey = await _native.hasSecret('sarvam');
      _callRole = await _native.hasCallScreeningRole();
      _overlayPermission = await _native.hasOverlayPermission();
      _fullScreenIntentPermission = await _native.hasFullScreenIntentPermission();
      final prefs = await SharedPreferences.getInstance();
      final chatRaw = prefs.getString(_chatHistoryKey);
      if (chatRaw != null) {
        try {
          final decoded = jsonDecode(chatRaw);
          if (decoded is List) {
            _chat = decoded.whereType<Map>().map((row) => <String, String>{
              'role': row['role']?.toString() ?? 'assistant',
              'content': row['content']?.toString() ?? '',
            }).where((row) => row['content']!.isNotEmpty).toList();
          }
        } catch (_) {
          _chat = <Map<String, String>>[];
        }
      }
      _eventLog = prefs.getStringList(_eventHistoryKey) ?? <String>[];
      if (_hasGroqKey) {
        try { _models = await _groq.fetchModels(); } catch (_) { /* Offline fallback catalogue remains usable. */ }
      }
    } catch (error) {
      _showStatus('Jenny settings could not be loaded: $error', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _wakeUiTimer?.cancel();
    _tabs.dispose();
    _groqKey.dispose();
    _sarvamKey.dispose();
    _context.dispose();
    _busyMessage.dispose();
    _sleepMessage.dispose();
    _missedMessage.dispose();
    _chatInput.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  void _showStatus(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _statusMessage = message;
      _statusIsError = error;
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _action(Future<void> Function() work) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
    } catch (error) {
      _showStatus(error.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveSecret(String provider, TextEditingController controller) async {
    final secret = controller.text.trim();
    if (secret.isEmpty) {
      _showStatus('Enter the API key first.', error: true);
      return;
    }
    await _native.saveSecret(provider, secret);
    controller.clear();
    if (provider == 'groq') {
      _hasGroqKey = true;
      await _settings.setValue('groqModel', _settings.get<String>('groqModel'));
      try {
        setState(() => _modelsLoading = true);
        _models = await _groq.fetchModels();
        _recordEvent('Groq model catalogue refreshed');
        _showStatus('Groq key encrypted and saved on this device.');
      } catch (error) {
        _showStatus('Key saved securely, but model refresh failed: $error', error: true);
      } finally {
        if (mounted) setState(() => _modelsLoading = false);
      }
    } else {
      _hasSarvamKey = true;
      _showStatus('Sarvam voice key encrypted and saved on this device.');
    }
    if (mounted) setState(() {});
  }

  Future<void> _removeSecret(String provider) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${provider == 'groq' ? 'Groq' : 'Sarvam'} key?'),
        content: const Text('The saved key and its device encryption key will be removed. Cloud-backed features for this provider will stop until a key is added again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Remove key')),
        ],
      ),
    );
    if (confirm != true) return;
    await _native.deleteSecret(provider);
    if (provider == 'groq') _hasGroqKey = false;
    if (provider == 'sarvam') _hasSarvamKey = false;
    _showStatus('${provider == 'groq' ? 'Groq' : 'Sarvam'} key removed.');
    if (mounted) setState(() {});
  }

  Future<void> _refreshModels() async {
    if (!_hasGroqKey) {
      _showStatus('Save a Groq API key on this device first.', error: true);
      return;
    }
    setState(() => _modelsLoading = true);
    try {
      _models = await _groq.fetchModels();
      _recordEvent('Groq model list refreshed');
      _showStatus('Available chat models refreshed from Groq.');
    } catch (error) {
      _showStatus('Could not fetch models. The saved offline catalogue remains available. $error', error: true);
    } finally {
      if (mounted) setState(() => _modelsLoading = false);
    }
  }

  Future<void> _saveContext() async {
    if (_context.text.trim().length < 20) {
      _showStatus('Add a clearer approved context or keep the existing context.', error: true);
      return;
    }
    await _settings.setValue('approvedContext', _context.text.trim());
    _recordEvent('Approved assistant context updated');
    _showStatus('Jenny’s approved context saved on this device.');
  }

  Future<void> _sendChat() async {
    final text = _chatInput.text.trim();
    if (text.isEmpty || _busy) return;
    if (JennyLocalPolicy.isEmergencyText(text)) {
      _chatInput.clear();
      await _native.openEmergencyDemo();
      _recordEvent('Emergency protocol opened by user');
      return;
    }
    _chatInput.clear();
    setState(() => _chat.add({'role': 'user', 'content': text}));
    await _persistChat();
    await _action(() async {
      if (_settings.get<bool>('localOnlyMode')) {
        const reply = 'I’m Jenny, Mayank’s personal AI assistant. Online AI is disabled on this device right now. I can show local settings, help with approved tasks, or pass an important message to Mayank.';
        _chat.add({'role': 'assistant', 'content': reply});
        await _persistChat();
        await _voice.speak(reply);
        return;
      }
      String answer;
      try {
        answer = await _groq.answer(
          userMessage: text,
          model: _settings.get<String>('groqModel'),
          approvedContext: _settings.get<String>('approvedContext'),
          assistantName: _settings.get<String>('assistantName'),
          history: _chat.take(_chat.length - 1).toList(growable: false),
        );
        _recordEvent('Jenny answered an in-app chat message');
      } catch (_) {
        answer = 'I’m Jenny, Mayank’s personal AI assistant. Online AI is not reachable right now, so I have not sent your message to any other service. I can still help with local settings or prepare a message for Mayank.';
        _recordEvent('Jenny used offline-safe chat fallback');
        _showStatus('Groq is unavailable. Jenny used a local fallback without further AI requests.', error: true);
      }
      _chat.add({'role': 'assistant', 'content': answer});
      await _persistChat();
      await _voice.speak(answer);
    });
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) _chatScroll.animateTo(
        _chatScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _persistChat() async {
    if (_chat.length > 80) _chat = _chat.sublist(_chat.length - 80);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_chatHistoryKey, jsonEncode(_chat));
  }

  Future<void> _clearChat() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear Jenny chat history?'),
        content: const Text('This removes the locally stored in-app Jenny chat transcript on this device. It does not delete SMS or call history in Android.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Keep history')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Clear history')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _chat.clear());
    await _persistChat();
    _recordEvent('Local Jenny chat history cleared');
  }

  Future<void> _startWakePhrase() async {
    final allowed = await _native.requestRuntimePermissions(const <String>['android.permission.RECORD_AUDIO']);
    if (!allowed) {
      _showStatus('Microphone permission is needed for voice commands.', error: true);
      return;
    }
    final started = await _voice.startForegroundWakePhrase(
      onWake: (command) => unawaited(_handleVoiceCommand(command)),
      onError: (message) => _showStatus('Voice listener: $message', error: true),
    );
    if (started) {
      _wakeUiTimer?.cancel();
      _recordEvent('Foreground Hey Jenny listener started (up to 25 seconds)');
      _showStatus('Listening for “Hey Jenny” while this screen stays open.');
      if (mounted) setState(() => _saying = true);
      _wakeUiTimer = Timer(const Duration(seconds: 26), () {
        if (mounted) setState(() => _saying = false);
      });
    }
  }

  Future<void> _handleVoiceCommand(String command) async {
    if (!mounted) return;
    _wakeUiTimer?.cancel();
    setState(() => _saying = false);
    final text = command.trim();
    if (text.isEmpty) {
      await _voice.speak('I’m here, Mayank. What would you like me to do?');
      return;
    }
    final lower = text.toLowerCase();
    if (lower == 'stop' || lower == 'stop listening' || lower == 'cancel') {
      await _voice.stopListening();
      await _voice.speak('Okay, I’ve stopped listening.');
      return;
    }
    if (RegExp(r'^(call|phone)\s+').hasMatch(lower)) {
      final contact = await _findContactByMention(text.replaceFirst(RegExp(r'^(call|phone)\s+', caseSensitive: false), ''));
      if (contact == null) {
        await _voice.speak('I couldn’t find that person in your saved contacts.');
        return;
      }
      await _native.openDialer(contact['number']!);
      await _voice.speak('I’ve opened the dialer for ${contact['name']}. Please confirm the call on your phone.');
      _recordEvent('Voice command opened dialer for saved contact ${contact['name']}');
      return;
    }
    if (RegExp(r'^(sms|text|message)\s+').hasMatch(lower)) {
      final parsed = await _parseContactCommand(text.replaceFirst(RegExp(r'^(sms|text|message)\s+', caseSensitive: false), ''));
      if (parsed == null) {
        await _voice.speak('Tell me a saved contact’s name followed by the message, for example, SMS Riya I will be ten minutes late.');
        return;
      }
      await _native.openSmsComposer(parsed.$1['number']!, parsed.$2);
      await _voice.speak('I’ve prepared a message for ${parsed.$1['name']}. Review it and tap send.');
      _recordEvent('Voice command opened SMS composer for ${parsed.$1['name']}');
      return;
    }
    if (RegExp(r'^(whatsapp|whats app)\s+').hasMatch(lower)) {
      final parsed = await _parseContactCommand(text.replaceFirst(RegExp(r'^(whatsapp|whats app)\s+', caseSensitive: false), ''));
      if (parsed == null) {
        await _voice.speak('Tell me a saved contact’s name and the message for WhatsApp.');
        return;
      }
      await _native.openWhatsApp(parsed.$1['number']!, parsed.$2);
      await _voice.speak('I’ve opened WhatsApp with a draft for ${parsed.$1['name']}. Review it and tap send.');
      _recordEvent('Voice command opened WhatsApp draft for ${parsed.$1['name']}');
      return;
    }
    _chatInput.text = text;
    await _sendChat();
  }

  Future<Map<String, String>?> _findContactByMention(String text) async {
    if (_contacts.isEmpty) {
      final granted = await _activity.requestContactsAccess();
      if (!granted) return null;
      _contacts = await _activity.contacts();
    }
    final lower = text.toLowerCase();
    final ordered = _contacts.toList()
      ..sort((a, b) => (b['name']?.toString().length ?? 0).compareTo(a['name']?.toString().length ?? 0));
    for (final contact in ordered) {
      final name = contact['name']?.toString().trim() ?? '';
      final number = contact['number']?.toString().trim() ?? '';
      if (name.isNotEmpty && number.isNotEmpty && lower.contains(name.toLowerCase())) {
        return <String, String>{'name': name, 'number': number};
      }
    }
    return null;
  }

  Future<(Map<String, String>, String)?> _parseContactCommand(String text) async {
    final contact = await _findContactByMention(text);
    if (contact == null) return null;
    final name = contact['name']!;
    final message = text.replaceFirst(RegExp(RegExp.escape(name), caseSensitive: false), '').trim();
    if (message.isEmpty) return null;
    return (contact, message);
  }

  Future<void> _beginEmergencyDemo() async {
    _recordEvent('Emergency alert demo opened by user');
    await _native.openEmergencyDemo();
  }

  Future<void> _loadActivity() async {
    try {
      final hasContacts = await _native.requestRuntimePermissions(const <String>['android.permission.READ_CONTACTS']);
      if (hasContacts) _contacts = await _activity.contacts();
      final smsAllowed = await _native.requestRuntimePermissions(const <String>[
        'android.permission.READ_SMS', 'android.permission.RECEIVE_SMS', 'android.permission.SEND_SMS',
      ]);
      if (smsAllowed) _sms = await _activity.smsHistory();
      final callsAllowed = await _native.requestRuntimePermissions(const <String>[
        'android.permission.READ_CALL_LOG', 'android.permission.READ_PHONE_STATE',
      ]);
      if (callsAllowed) _calls = await _activity.callHistory();
      _recordEvent('Phone activity requested by user');
      _showStatus('Activity view refreshed. Android may restrict SMS/call-log access unless Lanvi has an eligible default-handler role.');
    } catch (error) {
      _showStatus('Could not load phone activity: $error', error: true);
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _requestCallRole() async {
    final granted = await _native.requestCallScreeningRole();
    if (mounted) setState(() => _callRole = granted);
    _recordEvent(granted ? 'Call screening role granted' : 'Call screening role request dismissed');
    _showStatus(granted ? 'Lanvi can now apply local call-screening rules.' : 'Call-screening role was not granted. No calls will be screened by Jenny.');
  }

  Future<void> _requestOverlay() async {
    try {
      final allowed = await _native.requestOverlayPermission();
      if (allowed) {
        await _native.setOverlayEnabled(true);
        await _settings.setValue('overlayEnabled', true);
        _recordEvent('Jenny call overlay enabled');
      }
      if (mounted) setState(() => _overlayPermission = allowed);
      _showStatus(allowed ? 'Jenny’s call overlay enabled.' : 'Overlay permission was not granted.', error: !allowed);
    } catch (error) {
      _showStatus('Overlay could not be enabled: $error', error: true);
    }
  }

  Future<void> _requestFullScreenIntentPermission() async {
    try {
      await _native.requestRuntimePermissions(const <String>['android.permission.POST_NOTIFICATIONS']);
      await _native.requestFullScreenIntentPermission();
      final allowed = await _native.hasFullScreenIntentPermission();
      if (mounted) setState(() => _fullScreenIntentPermission = allowed);
      _showStatus(
        allowed
            ? 'Full-screen emergency-alert eligibility is enabled on this device.'
            : 'Android has not granted full-screen alert access. Jenny will fall back to a notification where required.',
        error: !allowed,
      );
    } catch (error) {
      _showStatus('Could not open full-screen alert settings: $error', error: true);
    }
  }

  Future<void> _recordEvent(String event) async {
    final stamp = DateTime.now().toIso8601String();
    _eventLog.insert(0, '$stamp · $event');
    if (_eventLog.length > 100) _eventLog = _eventLog.sublist(0, 100);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_eventHistoryKey, _eventLog);
    if (mounted) setState(() {});
  }

  Future<void> _openSavedContactAction(Map<String, Object?> contact, String action) async {
    final name = contact['name']?.toString() ?? 'contact';
    final number = contact['number']?.toString() ?? '';
    if (number.isEmpty) return;
    switch (action) {
      case 'call':
        await _native.openDialer(number);
        _recordEvent('Opened dialer for $name');
        break;
      case 'sms':
        await _native.openSmsComposer(number, 'Hi, this is Jenny, Mayank’s AI personal assistant.');
        _recordEvent('Opened SMS draft for $name');
        break;
      case 'whatsapp':
        await _native.openWhatsApp(number, 'Hi, this is Jenny, Mayank’s AI personal assistant.');
        _recordEvent('Opened WhatsApp draft for $name');
        break;
      case 'priority':
        final numbers = List<String>.from(_settings.get<List>('priorityNumbers').map((v) => v.toString()));
        final normalized = JennyLocalPolicy.normalizePhone(number);
        if (numbers.map(JennyLocalPolicy.normalizePhone).contains(normalized)) {
          numbers.removeWhere((v) => JennyLocalPolicy.normalizePhone(v) == normalized);
        } else {
          numbers.add(number);
        }
        await _settings.setValue('priorityNumbers', numbers);
        _showStatus(numbers.contains(number) ? '$name added to priority contacts.' : '$name removed from priority contacts.');
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return AnimatedBuilder(
      animation: _settings,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text('${_settings.get<String>('assistantName')} · Personal assistant'),
          bottom: TabBar(
            controller: _tabs,
            isScrollable: true,
            tabs: <Widget>[
              Tab(icon: Icon(PhosphorIcons.gridFour(PhosphorIconsStyle.light)), text: 'Overview'),
              Tab(icon: Icon(PhosphorIcons.sparkle(PhosphorIconsStyle.light)), text: 'Assistant & AI'),
              Tab(icon: Icon(PhosphorIcons.shieldCheck(PhosphorIconsStyle.light)), text: 'Automation'),
              Tab(icon: Icon(PhosphorIcons.clockCounterClockwise(PhosphorIconsStyle.light)), text: 'Activity'),
            ],
          ),
        ),
        body: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tabs,
                  children: <Widget>[
                    _buildOverview(theme, colors),
                    _buildAssistant(theme, colors),
                    _buildAutomation(theme, colors),
                    _buildActivity(theme, colors),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _pageList(List<Widget> children) => ListView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
        children: <Widget>[...children, const SizedBox(height: AppSpacing.xl)],
      );

  Widget _section(String title, String subtitle, IconData icon, List<Widget> children) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppRadius.large,
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Icon(icon, color: colors.primary, size: 24),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
        ]),
        const SizedBox(height: AppSpacing.xs),
        Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant, height: 1.4)),
        if (children.isNotEmpty) const SizedBox(height: AppSpacing.md),
        ...children,
      ]),
    );
  }

  Widget _statusTile(String title, String detail, bool enabled, IconData icon) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: enabled ? const Color(0xFF16834A) : Theme.of(context).colorScheme.onSurfaceVariant),
        title: Text(title),
        subtitle: Text(detail),
        trailing: Icon(enabled ? Icons.check_circle : Icons.radio_button_unchecked, color: enabled ? const Color(0xFF16834A) : null),
      );

  Widget _switchTile(String key, String title, String subtitle, {bool dangerous = false}) => SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        value: _settings.get<bool>(key),
        onChanged: (value) async {
          if (key == 'overlayEnabled') {
            if (value) {
              await _requestOverlay();
            } else {
              try {
                await _native.setOverlayEnabled(false);
                await _settings.setValue('overlayEnabled', false);
                _recordEvent('Jenny call overlay disabled');
              } catch (error) {
                _showStatus('Could not disable overlay: $error', error: true);
              }
            }
            return;
          }
          if (dangerous && value) {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('Enable automatic behavior?'),
                content: const Text('This feature may decline calls or send messages automatically. Use only after testing the rules and exemptions with trusted contacts.'),
                actions: <Widget>[
                  TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Enable')),
                ],
              ),
            );
            if (confirmed != true) return;
          }
          await _settings.setValue(key, value);
          _recordEvent('$title ${value ? 'enabled' : 'disabled'}');
        },
        title: Text(title),
        subtitle: Text(subtitle),
      );

  Widget _buildOverview(ThemeData theme, ColorScheme colors) => _pageList(<Widget>[
        Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(color: colors.primary, borderRadius: AppRadius.large),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Row(children: <Widget>[
              const CircleAvatar(backgroundColor: Colors.white, child: Icon(Icons.auto_awesome, color: Color(0xFF0F3D26))),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text('${_settings.get<String>('assistantName')} is Mayank’s personal AI assistant', style: theme.textTheme.titleLarge?.copyWith(color: colors.onPrimary, fontWeight: FontWeight.w800))),
            ]),
            const SizedBox(height: AppSpacing.sm),
            Text('Her job is to share your availability, handle approved tasks and flag important messages. She does not impersonate Mayank or answer outside approved context.', style: theme.textTheme.bodyMedium?.copyWith(color: colors.onPrimary.withOpacity(.9), height: 1.45)),
          ]),
        ),
        const SizedBox(height: AppSpacing.md),
        _section('Current mode', 'Choose the status and deterministic local response rules used for calls and SMS.', Icons.tune, <Widget>[
          SegmentedButton<String>(
            segments: const <ButtonSegment<String>>[
              ButtonSegment(value: 'normal', label: Text('Normal'), icon: Icon(Icons.check_circle_outline)),
              ButtonSegment(value: 'busy', label: Text('Busy'), icon: Icon(Icons.work_outline)),
              ButtonSegment(value: 'sleep', label: Text('Sleep'), icon: Icon(Icons.nightlight_outlined)),
            ],
            selected: <String>{_settings.mode},
            onSelectionChanged: (values) async {
              final value = values.isEmpty ? 'normal' : values.first;
              await _settings.setValue('mode', value);
              _recordEvent('Mode changed to $value');
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          _switchTile('autoReplyBusySleep', 'Automatic Busy / Sleep SMS', 'Fixed local templates; uses no AI tokens.'),
          _switchTile('autoReplyMissedCalls', 'Missed-call follow-up SMS', 'Fixed message for saved contacts only; no AI tokens.'),
          _switchTile('localOnlyMode', 'Local-only fail-safe mode', 'Disable Groq requests. Keep saved templates, local filters and on-device TTS.'),
        ]),
        _section('Device readiness', 'Sensitive features are off until you grant the required system role or permissions.', Icons.verified_user_outlined, <Widget>[
          _statusTile('Groq chat key', _hasGroqKey ? 'Saved in Android Keystore on this device' : 'No key saved · chat is unavailable', _hasGroqKey, Icons.key_outlined),
          _statusTile('Call-screening role', _callRole ? 'Granted by Android' : 'Not granted', _callRole, Icons.phone_in_talk_outlined),
          _statusTile('Overlay permission', _overlayPermission ? 'Allowed by Android' : 'Not allowed', _overlayPermission, Icons.picture_in_picture_alt_outlined),
          _statusTile('Encrypted local transfer', 'Separate from Jenny’s optional cloud AI features', true, Icons.lock_outline),
        ]),
        _section('Privacy by default', 'No AI request is made for blocked senders, unrecognized contacts, likely OTP / banking / promotional SMS, or local Busy / Sleep templates. AI SMS replies are disabled by default.', Icons.shield_outlined, <Widget>[
          _switchTile('aiSmsRepliesEnabled', 'AI SMS replies to saved contacts', 'When enabled, an eligible saved-contact message body is sent to Groq for a concise reply. Requires internet and a valid key.'),
          _statusTile('Saved-contact gate', 'Always enforced for automatic SMS conversations. Unknown senders never reach Groq.', true, Icons.contact_page_outlined),
          _switchTile('blockKnownSpam', 'Block configured spam numbers', 'Blocklist decisions are local and consume no model tokens.'),
        ]),
        if (_statusMessage != null) _statusBox(_statusMessage!, _statusIsError),
      ]);

  String _descriptionForSelectedModel() {
    if (_models.isEmpty) return 'No model information is available. Add a Groq key or use the offline configuration.';
    final selected = _settings.get<String>('groqModel');
    for (final model in _models) {
      if (model.id == selected) return model.description;
    }
    return _models.first.description;
  }

  Future<void> _addBlockedNumber() async {
    final controller = TextEditingController();
    final number = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Block a phone number'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.phone,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Phone number', hintText: '+91…'),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()), child: const Text('Add to blocklist')),
        ],
      ),
    );
    controller.dispose();
    if (number == null) return;
    final normalized = JennyLocalPolicy.normalizePhone(number);
    if (normalized.length < 8) {
      _showStatus('Enter a valid phone number with at least 8 digits.', error: true);
      return;
    }
    final existing = List<String>.from(_settings.get<List>('blockedNumbers').map((item) => item.toString()));
    if (existing.map(JennyLocalPolicy.normalizePhone).contains(normalized)) {
      _showStatus('That number is already blocked.');
      return;
    }
    existing.add(number);
    await _settings.setValue('blockedNumbers', existing);
    _recordEvent('Added a number to the local call/SMS blocklist');
    _showStatus('Number added to the local blocklist. No AI tokens are used for block decisions.');
  }

  Future<void> _removeBlockedNumber(String number) async {
    final existing = List<String>.from(_settings.get<List>('blockedNumbers').map((item) => item.toString()));
    existing.removeWhere((item) => JennyLocalPolicy.normalizePhone(item) == JennyLocalPolicy.normalizePhone(number));
    await _settings.setValue('blockedNumbers', existing);
    _recordEvent('Removed a number from the local call/SMS blocklist');
    _showStatus('Number removed from the blocklist.');
  }

  Widget _buildAssistant(ThemeData theme, ColorScheme colors) => _pageList(<Widget>[
        _section('Assistant identity', 'This configuration applies to this installation only. Different devices can use different names, models and keys.', Icons.face_retouching_natural_outlined, <Widget>[
          TextFormField(
            initialValue: _settings.get<String>('assistantName'),
            decoration: const InputDecoration(labelText: 'Assistant name', hintText: 'Jenny'),
            onFieldSubmitted: (value) => _settings.setValue('assistantName', value.trim().isEmpty ? 'Jenny' : value.trim()),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('Approved context (only information Jenny may share)', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.xs),
          TextField(controller: _context, minLines: 4, maxLines: 8, maxLength: 4000, decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Add public project details, status rules and safe facts about Mayank. Do not place secrets here.')),
          Align(alignment: Alignment.centerRight, child: FilledButton.icon(onPressed: _busy ? null : _saveContext, icon: const Icon(Icons.save_outlined), label: const Text('Save context'))),
        ]),
        _section('Groq model configuration', 'Keys are encrypted with Android Keystore on this device. Model names are fetched from Groq when the key and internet are available.', Icons.psychology_alt_outlined, <Widget>[
          TextField(
            controller: _groqKey,
            obscureText: !_showKeys,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Groq API key',
              hintText: _hasGroqKey ? 'A key is already saved on this device' : 'Paste your key',
              prefixIcon: const Icon(Icons.key_outlined),
              suffixIcon: IconButton(
                onPressed: () => setState(() => _showKeys = !_showKeys),
                icon: Icon(_showKeys ? Icons.visibility_off : Icons.visibility),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: <Widget>[
            FilledButton.icon(onPressed: _busy ? null : () => _action(() => _saveSecret('groq', _groqKey)), icon: const Icon(Icons.lock_outline), label: const Text('Encrypt & save key')),
            OutlinedButton.icon(onPressed: _modelsLoading || _busy ? null : _refreshModels, icon: _modelsLoading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh), label: const Text('Fetch models')),
            if (_hasGroqKey) TextButton.icon(onPressed: _busy ? null : () => _removeSecret('groq'), icon: const Icon(Icons.delete_outline), label: const Text('Remove key')),
          ]),
          const SizedBox(height: AppSpacing.md),
          DropdownButtonFormField<String>(
            value: _models.any((model) => model.id == _settings.get<String>('groqModel')) ? _settings.get<String>('groqModel') : _models.first.id,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Chat model for this device'),
            items: _models.map((model) => DropdownMenuItem<String>(value: model.id, child: Text(model.id, overflow: TextOverflow.ellipsis))).toList(growable: false),
            onChanged: (value) { if (value != null) _settings.setValue('groqModel', value); },
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            _descriptionForSelectedModel(),
            style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant, height: 1.45),
          ),
          const SizedBox(height: AppSpacing.sm),
          const Text('Model availability and rate limits depend on your Groq account. Model listing does not guarantee that a model is enabled for inference.', style: TextStyle(fontSize: 12)),
        ]),
        _section('Human-sounding Hindi / English voice', 'Recommended optional voice: Sarvam Bulbul v4 Flash with a female English–Hindi code-mixed persona. Speech text is sent to Sarvam only when you tap Speak or ask Jenny to speak.', Icons.record_voice_over_outlined, <Widget>[
          DropdownButtonFormField<String>(
            value: _settings.get<String>('voiceProvider'),
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Voice provider'),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem(value: 'system', child: Text('On-device system voice · offline fallback')),
              DropdownMenuItem(value: 'sarvam', child: Text('Sarvam Bulbul v4 Flash · cloud TTS')),
            ],
            onChanged: (value) async { if (value != null) await _settings.setValue('voiceProvider', value); },
          ),
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<String>(
            value: _settings.get<String>('voiceLanguage'),
            decoration: const InputDecoration(labelText: 'Voice language preference'),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem(value: 'hi-IN', child: Text('Hindi · India')),
              DropdownMenuItem(value: 'en-IN', child: Text('English · India')),
            ],
            onChanged: (value) async { if (value != null) await _settings.setValue('voiceLanguage', value); },
          ),
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<String>(
            value: _settings.get<String>('sarvamSpeaker'),
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Sarvam voice persona'),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem(value: 'ishita_enhi_customer', child: Text('Ishita · female English + Hindi')),
              DropdownMenuItem(value: 'simran_enhi_customer', child: Text('Simran · female English + Hindi')),
              DropdownMenuItem(value: 'roopa_hi_companion', child: Text('Roopa · female Hindi')),
            ],
            onChanged: (value) async { if (value != null) await _settings.setValue('sarvamSpeaker', value); },
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(controller: _sarvamKey, obscureText: !_showKeys, autocorrect: false, decoration: InputDecoration(labelText: 'Optional Sarvam API key', hintText: _hasSarvamKey ? 'A key is already saved on this device' : 'Paste key for the premium voice', prefixIcon: const Icon(Icons.key_outlined))),
          Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: <Widget>[
            OutlinedButton.icon(onPressed: _busy ? null : () => _action(() => _saveSecret('sarvam', _sarvamKey)), icon: const Icon(Icons.lock_outline), label: const Text('Save voice key')),
            if (_hasSarvamKey) TextButton(onPressed: _busy ? null : () => _removeSecret('sarvam'), child: const Text('Remove voice key')),
            FilledButton.icon(onPressed: _busy ? null : () => _action(() => _voice.speak('Hi Mayank, main Jenny hoon, aapki personal AI assistant. I can speak Hindi and English and help with approved tasks.')), icon: const Icon(Icons.volume_up_outlined), label: const Text('Preview Jenny voice')),
          ]),
          const SizedBox(height: AppSpacing.xs),
          const Text('Groq is used for chat, not Hindi speech synthesis. The optional Sarvam key is separate. If no internet/API is available, the app falls back to the installed device TTS voice.', style: TextStyle(fontSize: 12)),
        ]),
        _section('Talk to Jenny', 'Chat is user-initiated. “Hey Jenny” listens only while this screen is open and for up to 25 seconds; it is not an always-on background hotword service.', Icons.chat_bubble_outline, <Widget>[
          Container(
            height: 250,
            decoration: BoxDecoration(color: colors.surfaceContainerHighest.withOpacity(.35), border: Border.all(color: colors.outlineVariant), borderRadius: AppRadius.medium),
            child: _chat.isEmpty
                ? const Center(child: Padding(padding: EdgeInsets.all(20), child: Text('Start with “Hey Jenny, what is my status?” or ask about an approved Lanvi project.')))
                : ListView.builder(
                    controller: _chatScroll,
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    itemCount: _chat.length,
                    itemBuilder: (context, index) {
                      final item = _chat[index];
                      final user = item['role'] == 'user';
                      return Align(
                        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 330),
                          margin: const EdgeInsets.only(bottom: AppSpacing.xs),
                          padding: const EdgeInsets.all(AppSpacing.sm),
                          decoration: BoxDecoration(color: user ? colors.primaryContainer : colors.surface, borderRadius: AppRadius.medium, border: Border.all(color: colors.outlineVariant)),
                          child: Text(item['content'] ?? '', style: theme.textTheme.bodyMedium),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(children: <Widget>[
            Expanded(child: TextField(controller: _chatInput, minLines: 1, maxLines: 4, textInputAction: TextInputAction.send, onSubmitted: (_) => _sendChat(), decoration: const InputDecoration(hintText: 'Message Jenny…', border: OutlineInputBorder()))),
            const SizedBox(width: AppSpacing.xs),
            IconButton.filled(tooltip: 'Send to Jenny', onPressed: _busy ? null : _sendChat, icon: const Icon(Icons.send_rounded)),
          ]),
          Wrap(spacing: AppSpacing.sm, children: <Widget>[
            OutlinedButton.icon(onPressed: _saying ? null : _startWakePhrase, icon: const Icon(Icons.mic_none), label: const Text('Hey Jenny (foreground)')),
            OutlinedButton.icon(onPressed: () async { _wakeUiTimer?.cancel(); await _voice.stopListening(); if (mounted) setState(() => _saying = false); }, icon: const Icon(Icons.mic_off_outlined), label: const Text('Stop listening')),
            TextButton.icon(onPressed: _clearChat, icon: const Icon(Icons.delete_outline), label: const Text('Clear chat history')),
          ]),
        ]),
        if (_statusMessage != null) _statusBox(_statusMessage!, _statusIsError),
      ]);

  Widget _buildAutomation(ThemeData theme, ColorScheme colors) => _pageList(<Widget>[
        _section('Call screening', 'Requires Android 10+ and the user-selected call-screening role. Jenny applies local rules only; it does not use AI to decide whether a call should be rejected.', Icons.phone_in_talk_outlined, <Widget>[
          _statusTile('Call-screening role', _callRole ? 'Enabled on Android' : 'Not granted', _callRole, Icons.verified_user_outlined),
          Align(alignment: Alignment.centerLeft, child: FilledButton.icon(onPressed: _requestCallRole, icon: const Icon(Icons.security), label: Text(_callRole ? 'Check call-screening role' : 'Choose Lanvi for call screening'))),
          _switchTile('autoDeclineBusySleep', 'Decline eligible calls in Busy / Sleep', 'Only when you have explicitly enabled Busy/Sleep mode. Priority contacts are exempt.', dangerous: true),
          _switchTile('blockUnknownCallers', 'Block unknown callers in Busy / Sleep', 'Disabled by default. This may reject useful calls from numbers not saved in Contacts.', dangerous: true),
          _switchTile('blockKnownSpam', 'Reject numbers on your local blocklist', 'A local rule; no AI tokens are used.'),
          _switchTile('autoReplyBusySleep', 'Text saved contacts after an eligible rejected call', 'Fixed template with a 4-hour cooldown; no AI call is made.'),
          _switchTile('autoReplyMissedCalls', 'Text saved contacts after a missed call in Normal mode', 'Fixed template only; depends on device call-log/broadcast behavior.'),
        ]),
        _section('Local spam blocklist', 'Numbers on this list are checked on-device. No Groq request or token is used for these decisions. Only enable call rejection after confirming the entries.', Icons.block_outlined, <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _addBlockedNumber,
              icon: const Icon(Icons.add),
              label: const Text('Add blocked number'),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (_settings.get<List>('blockedNumbers').isEmpty)
            const Text('No custom blocked numbers yet. Android’s own caller-ID/spam screening remains separate.')
          else
            ...List<String>.from(_settings.get<List>('blockedNumbers').map((item) => item.toString())).map((number) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.phone_disabled_outlined),
              title: Text(number),
              subtitle: const Text('Local block rule'),
              trailing: IconButton(tooltip: 'Remove number', onPressed: () => _removeBlockedNumber(number), icon: const Icon(Icons.delete_outline)),
            )),
        ]),
        _section('Response messages', 'Edit deterministic messages. These templates do not consume AI tokens.', Icons.sms_outlined, <Widget>[
          TextField(controller: _busyMessage, minLines: 3, maxLines: 5, maxLength: 480, decoration: const InputDecoration(labelText: 'Busy mode SMS', border: OutlineInputBorder())),
          const SizedBox(height: AppSpacing.sm),
          TextField(controller: _sleepMessage, minLines: 3, maxLines: 5, maxLength: 480, decoration: const InputDecoration(labelText: 'Sleep mode SMS', border: OutlineInputBorder())),
          const SizedBox(height: AppSpacing.sm),
          TextField(controller: _missedMessage, minLines: 3, maxLines: 5, maxLength: 480, decoration: const InputDecoration(labelText: 'Normal missed-call SMS', border: OutlineInputBorder())),
          Align(alignment: Alignment.centerRight, child: FilledButton.icon(onPressed: () async => _settings.setMany(<String, Object?>{'busyMessage': _busyMessage.text.trim(), 'sleepMessage': _sleepMessage.text.trim(), 'missedCallMessage': _missedMessage.text.trim()}), icon: const Icon(Icons.save_outlined), label: const Text('Save templates'))),
        ]),
        _section('SMS automation and token protection', 'The receiver filters blocked, unknown, short-code, OTP, banking, transactional and promotional traffic locally before AI. Automatic AI replies are off by default.', Icons.filter_alt_outlined, <Widget>[
          _switchTile('aiSmsRepliesEnabled', 'Enable AI replies for eligible saved contacts', 'Message content goes to Groq only after local filters pass. Turn off to avoid SMS-related AI usage.'),
          _statusTile('Saved-contact-only AI', 'Enforced locally. Unknown senders and business/OTP traffic are filtered before any AI request.', true, Icons.verified_user_outlined),
          _switchTile('localOnlyMode', 'Offline / local-only mode', 'Completely bypasses Groq. Only deterministic rules and on-device voice are used.'),
          _switchTile('emergencyAlertsEnabled', 'Emergency phrase alerts', 'Check urgent messages locally and show a high-priority alert. It cannot replace emergency services.'),
          _switchTile('emergencyMaxVolume', 'Temporarily raise alarm volume for emergency', 'Enabled by default after a confirmed emergency. Jenny raises alarm volume during the alert and restores the prior level on dismiss.', dangerous: true),
          _statusTile('Proactive check-ins', 'Not active in this build. Always-on background wake-word listening is not enabled.', false, Icons.schedule_outlined),
        ]),
        _section('Overlay and notifications', 'Overlay is opt-in. Android version, OEM battery policy and notification settings affect whether a floating surface can appear.', Icons.picture_in_picture_alt_outlined, <Widget>[
          _statusTile('Display over other apps', _overlayPermission ? 'Permission granted' : 'Permission required', _overlayPermission, Icons.layers_outlined),
          FilledButton.icon(onPressed: _requestOverlay, icon: const Icon(Icons.open_in_new), label: const Text('Grant overlay permission & enable')),
          _switchTile('overlayEnabled', 'Enable Jenny call overlay', 'Floating local controls where Android permits it. Does not answer a cellular call or route call audio.'),
          _statusTile('Full-screen emergency alerts', _fullScreenIntentPermission ? 'Allowed or not restricted on this Android version' : 'Android may require a separate app setting', _fullScreenIntentPermission, Icons.emergency_outlined),
          OutlinedButton.icon(onPressed: _requestFullScreenIntentPermission, icon: const Icon(Icons.open_in_new), label: const Text('Notification & full-screen alert access')),
          OutlinedButton.icon(onPressed: () async => _native.openNotificationPolicySettings(), icon: const Icon(Icons.notifications_active_outlined), label: const Text('Do Not Disturb / alarm policy settings')),
          OutlinedButton.icon(onPressed: _beginEmergencyDemo, icon: const Icon(Icons.emergency_outlined), label: const Text('Test emergency screen, sound and voice')),
        ]),
        _section('Permissions checklist', 'Request only the permissions needed for each feature. Android and Google Play may restrict SMS/call-log permissions to eligible default handlers.', Icons.admin_panel_settings_outlined, <Widget>[
          Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: <Widget>[
            OutlinedButton.icon(onPressed: () => _action(() async { final ok = await _native.requestRuntimePermissions(const <String>['android.permission.READ_CONTACTS']); _showStatus(ok ? 'Contacts access granted.' : 'Contacts access not granted.', error: !ok); }), icon: const Icon(Icons.contacts_outlined), label: const Text('Contacts')),
            OutlinedButton.icon(onPressed: () => _action(() async { final ok = await _native.requestRuntimePermissions(const <String>['android.permission.READ_SMS', 'android.permission.RECEIVE_SMS', 'android.permission.SEND_SMS']); _showStatus(ok ? 'SMS permissions granted.' : 'SMS access not granted.', error: !ok); }), icon: const Icon(Icons.sms_outlined), label: const Text('SMS')),
            OutlinedButton.icon(onPressed: () => _action(() async { final ok = await _native.requestRuntimePermissions(const <String>['android.permission.READ_CALL_LOG', 'android.permission.READ_PHONE_STATE']); _showStatus(ok ? 'Call-log permissions granted.' : 'Call-log access not granted.', error: !ok); }), icon: const Icon(Icons.call_outlined), label: const Text('Call log')),
            OutlinedButton.icon(onPressed: () => _action(() async { final ok = await _native.requestRuntimePermissions(const <String>['android.permission.RECORD_AUDIO', 'android.permission.POST_NOTIFICATIONS']); _showStatus(ok ? 'Microphone and notification permissions granted.' : 'One or more permissions were not granted.', error: !ok); }), icon: const Icon(Icons.mic_none), label: const Text('Voice + notifications')),
          ]),
        ]),
        _section('Safety boundary', 'Jenny does not secretly record calls, impersonate Mayank, or use AI to decide spam-call blocks. Cellular AI conversation audio is not provided by this feature; live two-way AI calls require a separate VoIP design.', Icons.info_outline, const <Widget>[]),
      ]);

  Widget _buildActivity(ThemeData theme, ColorScheme colors) => _pageList(<Widget>[
        _section('Saved contacts', 'Jenny’s automatic SMS chat and automatic call replies are intended for saved contacts only. Actions below open the system app or a draft; you must confirm calls and messages there.', Icons.contacts_outlined, <Widget>[
          OutlinedButton.icon(onPressed: () => _action(_loadActivity), icon: const Icon(Icons.refresh), label: const Text('Load contacts, SMS and call history')),
          if (_contacts.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: AppSpacing.sm), child: Text('Contacts have not been loaded. Tap the button above and grant access if you want to use these features.'))
          else
            ..._contacts.take(80).map((contact) {
              final name = contact['name']?.toString() ?? 'Contact';
              final number = contact['number']?.toString() ?? '';
              final priorities = List<String>.from(_settings.get<List>('priorityNumbers').map((item) => item.toString()));
              final isPriority = priorities.map(JennyLocalPolicy.normalizePhone).contains(JennyLocalPolicy.normalizePhone(number));
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(number),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) => _openSavedContactAction(contact, value),
                  itemBuilder: (_) => <PopupMenuEntry<String>>[
                    const PopupMenuItem(value: 'call', child: Text('Open dialer')),
                    const PopupMenuItem(value: 'sms', child: Text('Draft SMS')),
                    const PopupMenuItem(value: 'whatsapp', child: Text('Draft WhatsApp')),
                    PopupMenuItem(value: 'priority', child: Text(isPriority ? 'Remove priority status' : 'Mark priority contact')),
                  ],
                ),
              );
            }),
        ]),
        _section('Recent SMS', 'Loaded from the device only after you grant permission. No message is sent to Groq by opening this list.', Icons.sms_outlined, <Widget>[
          if (_sms.isEmpty)
            const Text('No SMS loaded yet. Grant SMS access above or in the Automation tab.')
          else
            ..._sms.take(30).map((item) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.message_outlined),
              title: Text(item['address']?.toString() ?? 'Unknown sender', maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(item['body']?.toString() ?? '', maxLines: 3, overflow: TextOverflow.ellipsis),
              trailing: Text(_formatEpoch(item['date']), style: theme.textTheme.labelSmall),
            )),
        ]),
        _section('Recent calls', 'Read from Android call history only after permission and OS policy allow it.', Icons.call_outlined, <Widget>[
          if (_calls.isEmpty)
            const Text('No call history loaded yet. Grant call-log access on an eligible personal/sideload setup.')
          else
            ..._calls.take(30).map((item) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(_callTypeIcon(item['type'])),
              title: Text((item['name']?.toString().trim().isNotEmpty ?? false) ? item['name'].toString() : (item['number']?.toString() ?? 'Unknown caller'), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${item['number'] ?? ''} · ${item['duration'] ?? 0}s'),
              trailing: Text(_formatEpoch(item['date']), style: theme.textTheme.labelSmall),
            )),
        ]),
        _section('Jenny activity log', 'Local app event history: model settings, voice activation, mode changes and user-triggered actions. This is not a record of every Android event.', Icons.history_toggle_off_outlined, <Widget>[
          if (_eventLog.isEmpty)
            const Text('No Jenny events recorded yet.')
          else
            ..._eventLog.take(40).map((event) => Padding(padding: const EdgeInsets.only(bottom: AppSpacing.xs), child: Text(event, style: theme.textTheme.bodySmall))),
          Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: () => _action(() async { _eventLog.clear(); final prefs = await SharedPreferences.getInstance(); await prefs.setStringList(_eventHistoryKey, _eventLog); setState(() {}); }), icon: const Icon(Icons.delete_outline), label: const Text('Clear activity log'))),
        ]),
      ]);

  Widget _statusBox(String message, bool error) => Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: (error ? Theme.of(context).colorScheme.errorContainer : Theme.of(context).colorScheme.primaryContainer).withOpacity(.7),
          borderRadius: AppRadius.medium,
        ),
        child: Row(children: <Widget>[
          Icon(error ? Icons.warning_amber_rounded : Icons.check_circle_outline),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(message)),
        ]),
      );

  String _formatEpoch(Object? value) {
    final millis = value is num ? value.toInt() : int.tryParse(value?.toString() ?? '') ?? 0;
    if (millis <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(millis);
    final local = date.toLocal();
    return '${local.day}/${local.month} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  IconData _callTypeIcon(Object? value) {
    final type = value is num ? value.toInt() : int.tryParse(value?.toString() ?? '') ?? 0;
    if (type == 1) return Icons.call_received;
    if (type == 2) return Icons.call_made;
    if (type == 3) return Icons.call_missed;
    return Icons.phone_outlined;
  }
}
