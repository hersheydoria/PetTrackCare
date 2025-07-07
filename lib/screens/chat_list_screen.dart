import 'package:flutter/material.dart';
import 'chat_detail_screen.dart';

class ChatListScreen extends StatelessWidget {
  final List<Map<String, String>> dummyChats = [
    {'name': 'Emily (Sitter)', 'lastMessage': 'See you later!'},
    {'name': 'John (Owner)', 'lastMessage': 'Thank you so much!'},
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Messages'),
        backgroundColor: Color(0xFFCB4154),
      ),
      body: ListView.builder(
        itemCount: dummyChats.length,
        itemBuilder: (context, index) {
          final chat = dummyChats[index];
          return ListTile(
            leading: CircleAvatar(child: Text(chat['name']![0])),
            title: Text(chat['name']!),
            subtitle: Text(chat['lastMessage']!),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatDetailScreen(
                    userName: chat['name']!,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
