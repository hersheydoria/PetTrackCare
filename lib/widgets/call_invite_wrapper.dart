import 'package:flutter/material.dart';
import '../services/call_invite_service.dart';

/// A wrapper widget that initializes the call invite service
/// and updates its context when the widget rebuilds.
/// 
/// Usage: Wrap your main app content with this widget to enable
/// global incoming call alerts across all screens.
class CallInviteWrapper extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState>? navigatorKey;
  
  const CallInviteWrapper({
    Key? key,
    required this.child,
    this.navigatorKey,
  }) : super(key: key);

  @override
  _CallInviteWrapperState createState() => _CallInviteWrapperState();
}

class _CallInviteWrapperState extends State<CallInviteWrapper> {
  final _callService = CallInviteService();

  @override
  void initState() {
    super.initState();
    print('📞 CallInviteWrapper: initState called');
    // Initialize the service after the first frame is built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        print('📞 CallInviteWrapper: Initializing call service with context');
        _callService.registerNavigatorKey(widget.navigatorKey);
        _callService.initialize(context);
      } else {
        print('📞 CallInviteWrapper: Widget not mounted, skipping initialization');
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    print('📞 CallInviteWrapper: didChangeDependencies called - updating context');
    // Update context when dependencies change (e.g., navigation)
    _callService.updateContext(context);
    _callService.registerNavigatorKey(widget.navigatorKey);
  }

  @override
  void dispose() {
    print('📞 CallInviteWrapper: dispose called - cleaning up call service');
    _callService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
