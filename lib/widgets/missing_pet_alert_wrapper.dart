import 'package:flutter/material.dart';
import '../services/missing_pet_alert_service.dart';

/// A wrapper widget that initializes the missing pet alert service
/// and updates its context when the widget rebuilds.
/// 
/// Usage: Wrap your main app content with this widget to enable
/// global missing pet alerts across all screens.
class MissingPetAlertWrapper extends StatefulWidget {
  final Widget child;
  
  const MissingPetAlertWrapper({
    Key? key,
    required this.child,
  }) : super(key: key);

  @override
  _MissingPetAlertWrapperState createState() => _MissingPetAlertWrapperState();
}

class _MissingPetAlertWrapperState extends State<MissingPetAlertWrapper> {
  final _alertService = MissingPetAlertService();

  @override
  void initState() {
    super.initState();
    print('🔔 MissingPetAlertWrapper: initState called');
    // Initialize the service after the first frame is built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        print('🔔 MissingPetAlertWrapper: Initializing alert service with context');
        _alertService.initialize(context);
      } else {
        print('🔔 MissingPetAlertWrapper: Widget not mounted, skipping initialization');
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    print('🔔 MissingPetAlertWrapper: didChangeDependencies called - updating context');
    // Update context when dependencies change (e.g., navigation)
    _alertService.updateContext(context);
  }

  @override
  void dispose() {
    print('🔔 MissingPetAlertWrapper: dispose called - cleaning up alert service');
    _alertService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}