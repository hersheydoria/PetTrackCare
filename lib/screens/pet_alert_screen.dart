import 'package:flutter/material.dart';

class PetAlertScreen extends StatelessWidget {
  final String petId;
  const PetAlertScreen({Key? key, required this.petId}) : super(key: key);

  static PetAlertScreen fromRoute(BuildContext context) {
    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    final petId = args?['petId']?.toString() ?? '';
    return PetAlertScreen(petId: petId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pet Alert')),
      body: Center(
        child: Text('Pet ID: $petId'),
      ),
    );
  }
}
