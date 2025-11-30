import 'package:flutter/material.dart';

typedef DialogAction = Future<void> Function(BuildContext context);

class IncomingCallDialog extends StatelessWidget {
  final String callerName;
  final bool isVideo;
  final String? subtitle;
  final DialogAction onAccept;
  final DialogAction onDecline;

  const IncomingCallDialog({
    super.key,
    required this.callerName,
    required this.isVideo,
    required this.onAccept,
    required this.onDecline,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final Color accent = isVideo ? const Color(0xFFB82132) : const Color(0xFF1ABC9C);
    final IconData icon = isVideo ? Icons.videocam_rounded : Icons.call_rounded;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
      titlePadding: EdgeInsets.zero,
      title: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [accent, accent.withOpacity(0.8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isVideo ? 'Incoming video call' : 'Incoming voice call',
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Answer to connect instantly',
              style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 13),
            ),
          ],
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 46,
            backgroundColor: accent.withOpacity(0.15),
            child: Icon(icon, color: accent, size: 36),
          ),
          const SizedBox(height: 16),
          Text(
            callerName,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle ?? 'is calling you…',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
            textAlign: TextAlign.center,
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        SizedBox(
          width: double.infinity,
          child: Row(
            children: [
              Expanded(
                flex: 1,
                child: TextButton.icon(
                  onPressed: () => onDecline(context),
                  icon: const Icon(Icons.call_end, color: Colors.red),
                  label: const Text('Decline', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
                  style: TextButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: ElevatedButton.icon(
                  onPressed: () => onAccept(context),
                  icon: const Icon(Icons.call, color: Colors.white),
                  label: const Text('Accept', style: TextStyle(fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(52),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class OutgoingCallDialog extends StatelessWidget {
  final String calleeName;
  final bool isVideo;
  final String? subtitle;
  final DialogAction onCancel;

  const OutgoingCallDialog({
    super.key,
    required this.calleeName,
    required this.isVideo,
    required this.onCancel,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final Color accent = isVideo ? const Color(0xFFB82132) : const Color(0xFF1ABC9C);
    final IconData icon = isVideo ? Icons.videocam_outlined : Icons.call_outlined;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
      titlePadding: EdgeInsets.zero,
      title: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [accent, accent.withOpacity(0.8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isVideo ? 'Calling via video' : 'Calling via voice',
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Waiting for response…',
              style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 13),
            ),
          ],
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 46,
            backgroundColor: accent.withOpacity(0.15),
            child: Icon(icon, color: accent, size: 36),
          ),
          const SizedBox(height: 16),
          Text(
            calleeName,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle ?? 'Connecting…',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          const LinearProgressIndicator(minHeight: 4),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        SizedBox(
          width: double.infinity,
          child: TextButton.icon(
            onPressed: () => onCancel(context),
            icon: const Icon(Icons.call_end, color: Colors.red),
            label: const Text('Cancel call', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              backgroundColor: Colors.red.withOpacity(0.08),
            ),
          ),
        ),
      ],
    );
  }
}
