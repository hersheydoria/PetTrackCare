import 'package:flutter/material.dart';

// Matching the pet profile color scheme
const lightBlush = Color(0xFFF6DED8);
const peach = Color(0xFFF2B28C);
const deepRed = Color(0xFFB82132);

class CommunityScreen extends StatelessWidget {
  const CommunityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: lightBlush,
      appBar: AppBar(
        backgroundColor: lightBlush,
        elevation: 0,
        title: const Text(
          'Community',
          style: TextStyle(fontWeight: FontWeight.bold, color: deepRed),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search, color: deepRed),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.notifications_none, color: deepRed),
            onPressed: () {},
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Story Section
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10.0),
              child: SizedBox(
                height: 100,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    const SizedBox(width: 10),
                    _buildAddStory(context),
                    _buildStory('assets/avatar1.png', 'Anna'),
                    _buildStory('assets/avatar2.png', 'Jake'),
                    _buildStory('assets/avatar3.png', 'Nina'),
                  ],
                ),
              ),
            ),

            // Feed Section
            _buildPostCard(
              name: 'May Estroga',
              role: 'Owner',
              time: '2 hours ago',
              content: 'Just took my dog for a walk! 🐾',
              image: 'assets/dog_walk.png',
            ),
            _buildPostCard(
              name: 'John Reyes',
              role: 'Sitter',
              time: '3 hours ago',
              content: 'Available for weekend sitting!',
              image: 'assets/pet_sitter.png',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddStory(BuildContext context) {
    return GestureDetector(
      onTap: () {}, // Show modal or navigate
      child: Column(
        children: [
          CircleAvatar(
            radius: 30,
            backgroundColor: peach,
            child: const Icon(Icons.add_a_photo, color: Colors.white),
          ),
          const SizedBox(height: 5),
          const Text('Add Story', style: TextStyle(color: deepRed)),
        ],
      ),
    );
  }

  Widget _buildStory(String avatar, String name) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: Column(
        children: [
          CircleAvatar(radius: 30, backgroundImage: AssetImage(avatar)),
          const SizedBox(height: 5),
          Text(name, style: const TextStyle(fontSize: 12, color: Colors.black)),
        ],
      ),
    );
  }

  Widget _buildPostCard({
    required String name,
    required String role,
    required String time,
    required String content,
    required String image,
  }) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      color: Colors.white,
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // User Info Row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: role == 'Owner' ? Colors.green[100] : Colors.blue[100],
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        role,
                        style: TextStyle(
                          fontSize: 10,
                          color: role == 'Owner' ? Colors.green : Colors.blue,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(time, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 10),

            // Post Content
            Text(content),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset(image, fit: BoxFit.cover),
            ),
            const SizedBox(height: 10),

            // Reaction Row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                IconButton(
                  icon: const Icon(Icons.favorite_border, color: deepRed),
                  onPressed: () {},
                ),
                IconButton(
                  icon: const Icon(Icons.comment_outlined, color: deepRed),
                  onPressed: () {},
                ),
                IconButton(
                  icon: const Icon(Icons.bookmark_border, color: deepRed),
                  onPressed: () {},
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
