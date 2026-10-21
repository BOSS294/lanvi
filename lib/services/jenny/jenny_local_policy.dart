// Purpose: Prevent Groq token use for spam, business alerts, OTPs, and unknown senders.
// Integration: Use before every automatic SMS-to-AI request.
// Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: All classification is deterministic and offline; this does not call an AI model.

class JennyGateDecision {
  const JennyGateDecision({required this.allowed, required this.reason});
  final bool allowed;
  final String reason;
}

class JennyLocalPolicy {
  JennyLocalPolicy._();

  static const List<String> _skipPatterns = <String>[
    r'\botp\b',
    r'\bone[- ]time password\b',
    r'\bverification code\b',
    r'\bdo not share\b',
    r'\btransaction (?:alert|successful|failed)\b',
    r'\b(?:credited|debited)\b',
    r'\b(?:bank|upi|credit card|debit card)\b',
    r'\b(?:unsubscribe|promotional|promo code|limited offer|discount|loan offer)\b',
    r'https?://|www\.',
  ];

  static JennyGateDecision evaluateIncomingSms({
    required String sender,
    required String body,
    required bool senderIsSavedContact,
    required bool isBlocked,
    required bool aiRepliesEnabled,
  }) {
    if (isBlocked) return const JennyGateDecision(allowed: false, reason: 'Sender is blocked locally.');
    if (!senderIsSavedContact) {
      return const JennyGateDecision(allowed: false, reason: 'Unknown sender: Jenny only chats with saved contacts.');
    }
    final compactSender = sender.replaceAll(RegExp(r'[^0-9+]'), '');
    if (compactSender.length < 8) {
      return const JennyGateDecision(allowed: false, reason: 'Short code or automated sender; no AI request.');
    }
    final normalized = body.toLowerCase();
    for (final pattern in _skipPatterns) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(normalized)) {
        return const JennyGateDecision(allowed: false, reason: 'Likely OTP, transactional, business or promotional SMS; no AI request.');
      }
    }
    if (!aiRepliesEnabled) {
      return const JennyGateDecision(allowed: false, reason: 'Automatic AI SMS replies are disabled.');
    }
    if (body.trim().isEmpty) return const JennyGateDecision(allowed: false, reason: 'Empty message.');
    return const JennyGateDecision(allowed: true, reason: 'Saved contact; passed local filters.');
  }

  static bool isEmergencyText(String body) => RegExp(
        r'\b(emergency|urgent|accident|hospital|danger|help me|need help|critical)\b|आपातकाल|इमरजेंसी|दुर्घटना|अस्पताल|मदद चाहिए|खतरा',
        caseSensitive: false,
      ).hasMatch(body);

  static bool isLikelySpamCall({required String number, required List<String> blockedNumbers}) {
    final normalized = normalizePhone(number);
    if (normalized.isEmpty) return true;
    return blockedNumbers.any((item) => normalizePhone(item) == normalized);
  }

  static String normalizePhone(String value) => value.replaceAll(RegExp(r'[^0-9]'), '').replaceFirst(RegExp(r'^0+'), '');
}
