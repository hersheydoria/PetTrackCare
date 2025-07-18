// notification_screen.dart
import 'package:flutter/material.dart';

class NotificationScreen extends StatelessWidget {
  const NotificationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Sample static notifications
    final notifications = [
      'You have a new follower!',
      'Your post received a like.',
      'Reminder: Walk your dog today!',
      'Your appointment is confirmed.',
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFCB4154),
        title: Text('Notifications', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView.separated(
        padding: EdgeInsets.all(16),
        itemCount: notifications.length,
        separatorBuilder: (_, __) => Divider(),
        itemBuilder: (context, index) {
          return ListTile(
            leading: Icon(Icons.notifications_active),
            title: Text(notifications[index]),
            onTap: () {
              // You can handle click events here
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Tapped: ${notifications[index]}')),
              );
            },
          );
        },
      ),
    );
  }
}
