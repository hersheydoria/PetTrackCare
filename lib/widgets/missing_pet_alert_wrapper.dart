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
    // Initialize the service after the first frame is built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _alertService.initialize(context);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Update context when dependencies change (e.g., navigation)
    _alertService.updateContext(context);
  }

  @override
  void dispose() {
    _alertService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}