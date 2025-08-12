import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart'; // For date formatting
import 'notification_screen.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:fl_chart/fl_chart.dart';

// Color palette
const deepRed = Color(0xFFB82132);
const coral = Color(0xFFD2665A);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

class PetProfileScreen extends StatefulWidget {
  @override
  _PetProfileScreenState createState() => _PetProfileScreenState();
}

class _PetProfileScreenState extends State<PetProfileScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final user = Supabase.instance.client.auth.currentUser;

  List<Map<String, dynamic>> _pets = [];
  Map<String, dynamic>? _selectedPet;

  String backendUrl = "http://192.168.100.23:5000"; // set to your deployed backend
  List<double> _sleepTrend = []; // next 7 days predicted sleep hours
  Map<String, double> _moodProb = {};
  Map<String, double> _activityProb = {};

  // Behavior tab state
  String? _selectedBehavior;
  DateTime? _selectedDate = DateTime.now();
  String? _prediction;
  String? _recommendation;

  // 🔹 Moved from local scope to state variables
  String? _selectedMood;
  String? _activityLevel;
  double? _sleepHours;
  String? _notes;

  final List<String> _behaviors = [
    "Active", "Sleepy", "Aggressive", "Happy", "Anxious",
    "Playful", "Eating", "Not Eating", "Restless", "Lethargic"
  ];

  final List<String> moods = [
    "Happy", "Anxious", "Aggressive", "Calm", "Lethargic"
  ];

  final List<String> activityLevels = ["High", "Medium", "Low"];

  Future<Map<String, dynamic>?> _fetchLatestPet() async {
    final response = await Supabase.instance.client
        .from('pets')
        .select()
        .eq('owner_id', user?.id)
        .order('id', ascending: false)
        .limit(1)
        .execute();

    final data = response.data as List?;
    if (data == null || data.isEmpty) return null;
    return data.first as Map<String, dynamic>;
  }

  Future<void> _fetchPets() async {
    final response = await Supabase.instance.client
        .from('pets')
        .select()
        .eq('owner_id', user?.id)
        .order('id', ascending: false)
        .execute();

    final data = response.data as List?;
    if (data != null && data.isNotEmpty) {
      setState(() {
        _pets = List<Map<String, dynamic>>.from(data);
        _selectedPet = _pets.first;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _fetchPets();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: lightBlush,
      appBar: AppBar(
        backgroundColor: const Color(0xFFCB4154),
        elevation: 0,
        title: Text('Pet Profile', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: Icon(Icons.notifications),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const NotificationScreen(),
                ),
              );
            },
          ),
          PopupMenuButton<Map<String, dynamic>>(
            icon: Icon(Icons.more_vert),
            onSelected: (pet) {
              setState(() {
                _selectedPet = pet;
              });
            },
            itemBuilder: (context) {
              return _pets.map((pet) {
                return PopupMenuItem(
                  value: pet,
                  child: Text(
                    pet['name'] ?? 'Unnamed',
                    style: TextStyle(
                      fontWeight: pet == _selectedPet
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: pet == _selectedPet ? deepRed : Colors.black,
                    ),
                  ),
                );
              }).toList();
            },
          ),
        ],
      ),
      body: _selectedPet == null
          ? Center(child: CircularProgressIndicator(color: deepRed))
          : SingleChildScrollView(
              padding: EdgeInsets.only(bottom: 16),
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Column(
                      children: [
                        CircleAvatar(
                          radius: 60,
                          backgroundImage: _selectedPet!['profile_picture'] !=
                                      null &&
                                  _selectedPet!['profile_picture']
                                      .toString()
                                      .isNotEmpty
                              ? NetworkImage(_selectedPet!['profile_picture'])
                              : const AssetImage(
                                      'assets/pets-profile-pictures.png')
                                  as ImageProvider,
                        ),
                        SizedBox(height: 12),
                        Text(_selectedPet!['name'] ?? 'Unnamed',
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: deepRed)),
                        Text(_selectedPet!['breed'] ?? 'Unknown',
                            style: TextStyle(fontSize: 16)),
                        Text('${_selectedPet!['age']} years old',
                            style: TextStyle(
                                fontSize: 14, color: Colors.grey[700])),
                      ],
                    ),
                  ),

                  // ❤️ Health & ⚖️ Weight Card
                  Container(
                    margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: peach,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6)],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Column(
                          children: [
                            Icon(Icons.favorite, color: Colors.green),
                            SizedBox(height: 4),
                            Text('Health',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                            Text(_selectedPet!['health'] ?? 'Unknown'),
                          ],
                        ),
                        Column(
                          children: [
                            Icon(Icons.monitor_weight, color: deepRed),
                            SizedBox(height: 4),
                            Text('Weight',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                            Text('${_selectedPet!['weight']} kg'),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // 🧭 Tab Bar
                  Container(
                    margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        TabBar(
                          controller: _tabController,
                          indicatorColor: deepRed,
                          labelColor: deepRed,
                          unselectedLabelColor: Colors.grey,
                          tabs: [
                            Tab(icon: Icon(Icons.qr_code), text: 'QR Code'),
                            Tab(icon: Icon(Icons.location_on), text: 'Location'),
                            Tab(icon: Icon(Icons.bar_chart), text: 'Behavior'),
                          ],
                        ),
                        Divider(height: 1, color: Colors.grey.shade300),
                        Container(
                          height: 300,
                          padding: EdgeInsets.all(12),
                          child: TabBarView(
                            controller: _tabController,
                            children: [
                              _buildTabContent('QR Code Content Here'),
                              _buildTabContent('Location Content Here'),
                              _buildBehaviorTab(), // Updated Behavior Tab
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildTabContent(String text) {
    return Center(
      child: Text(
        text,
        style:
            TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: deepRed),
      ),
    );
  }

  Widget _buildBehaviorTab() {
  return SingleChildScrollView(
    child: Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Date Picker
          Text("Select Date", style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          InkWell(
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _selectedDate ?? DateTime.now(),
                firstDate: DateTime(2022),
                lastDate: DateTime(2100),
              );
              if (picked != null) {
                setState(() {
                  _selectedDate = picked;
                });
              }
            },
            child: Container(
              padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(8),
                color: Colors.white,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _selectedDate != null
                        ? DateFormat('yyyy-MM-dd').format(_selectedDate!)
                        : "Choose Date",
                    style: TextStyle(fontSize: 16),
                  ),
                  Icon(Icons.calendar_today, color: deepRed),
                ],
              ),
            ),
          ),

          SizedBox(height: 16),

          // Mood Dropdown
          Text("Mood", style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _selectedMood,
            decoration: InputDecoration(
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              filled: true,
              fillColor: Colors.white,
            ),
            items: moods.map((mood) {
              return DropdownMenuItem<String>(
                value: mood,
                child: Text(mood),
              );
            }).toList(),
            onChanged: (value) {
              setState(() {
                _selectedMood = value;
              });
            },
          ),

          SizedBox(height: 16),

          // Activity Level Dropdown
          Text("Activity Level", style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _activityLevel,
            decoration: InputDecoration(
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              filled: true,
              fillColor: Colors.white,
            ),
            items: activityLevels.map((level) {
              return DropdownMenuItem<String>(
                value: level,
                child: Text(level),
              );
            }).toList(),
            onChanged: (value) {
              setState(() {
                _activityLevel = value;
              });
            },
          ),

          SizedBox(height: 16),

          // Sleep Hours
          Text("Sleep Hours", style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          TextFormField(
            keyboardType: TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              filled: true,
              fillColor: Colors.white,
              hintText: "Enter sleep hours (0 - 24)",
            ),
            onChanged: (value) {
              setState(() {
                final parsed = double.tryParse(value);
                if (parsed == null || parsed < 0) {
                  _sleepHours = null; // invalid
                } else if (parsed > 24) {
                  _sleepHours = 24; // clamp
                } else {
                  _sleepHours = parsed;
                }
              });
            },
          ),

          SizedBox(height: 16),

          // Notes
          Text("Notes", style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          TextFormField(
            maxLines: 3,
            decoration: InputDecoration(
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              filled: true,
              fillColor: Colors.white,
              hintText: "Enter any additional notes",
            ),
            onChanged: (value) {
              setState(() {
                _notes = value;
              });
            },
          ),

          SizedBox(height: 16),

          // Log Button
          Center(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: deepRed,
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: Icon(Icons.save, color: Colors.white),
              label: Text("Log Behavior", style: TextStyle(color: Colors.white)),
              onPressed: (_selectedMood == null ||
                          _selectedDate == null ||
                          _activityLevel == null ||
                          _sleepHours == null)
                  ? null
                  : () async {
                      // 1) Insert to Supabase with error handling
                      try {
                        await Supabase.instance.client
                            .from('behavior_logs')
                            .insert({
                              'pet_id': _selectedPet!['id'],
                              'user_id': user?.id ?? '',
                              'log_date': DateFormat('yyyy-MM-dd').format(_selectedDate!),
                              'notes': _notes,
                              'mood': _selectedMood,
                              'sleep_hours': _sleepHours,
                              'activity_level': _activityLevel,
                            });

                        // 2) Call backend analyze endpoint
                        try {
                          final resp = await http.post(
                            Uri.parse(backendUrl),
                            headers: {'Content-Type': 'application/json'},
                            body: jsonEncode({
                              'pet_id': _selectedPet!['id'],
                              'mood': _selectedMood,
                              'sleep_hours': _sleepHours,
                              'activity_level': _activityLevel,
                            }),
                          );

                          if (resp.statusCode == 200) {
                            final body = jsonDecode(resp.body);
                            setState(() {
                              _prediction = body['prediction'];
                              _recommendation = body['recommendation'];
                              final trends = body['trends'] ?? {};
                              _sleepTrend = (trends['sleep_forecast'] as List<dynamic>?)
                                      ?.map((e) => (e as num).toDouble())
                                      .toList() ??
                                  [];
                              _moodProb =
                                  (trends['mood_probabilities'] as Map?)?.map((k, v) =>
                                          MapEntry(k.toString(), (v as num).toDouble())) ??
                                      {};
                              _activityProb =
                                  (trends['activity_probabilities'] as Map?)?.map((k, v) =>
                                          MapEntry(k.toString(), (v as num).toDouble())) ??
                                      {};
                            });

                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Behavior logged and analyzed!')),
                            );
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text(
                                      'Analysis unavailable (status ${resp.statusCode})')),
                            );
                          }
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Analysis failed: $e')),
                          );
                        }
                      } on PostgrestException catch (e) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Failed to save log: ${e.message}')),
                        );
                      } catch (e) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Unexpected error: $e')),
                        );
                      }
                    },
            ),
          ),

          SizedBox(height: 24),

          // Prediction Output
          if (_prediction != null)
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Prediction:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  SizedBox(height: 4),
                  Text(_prediction!, style: TextStyle(fontSize: 14, color: Colors.black87)),
                  SizedBox(height: 12),
                  Text("Recommendation:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  SizedBox(height: 4),
                  Text(_recommendation!, style: TextStyle(fontSize: 14, color: Colors.black87)),
                ],
              ),
            ),

          SizedBox(height: 18),

          if (_sleepTrend.isNotEmpty) ...[
            Text("7-day Sleep Forecast", style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            SizedBox(height: 12),
            Text("Mood distribution (recent):"),
            Text(_moodProb.isEmpty ? "No mood data" : _moodProb.entries.map((e)=>"${e.key}: ${(e.value*100).round()}%").join("  ·  ")),
            SizedBox(height: 8),
            Text("Activity distribution (recent):"),
            Text(_activityProb.isEmpty ? "No activity data" : _activityProb.entries.map((e)=>"${e.key}: ${(e.value*100).round()}%").join("  ·  ")),
          ],
        ],
      ),
    ),
  );
}
    }
