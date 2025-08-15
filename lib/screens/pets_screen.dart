import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart'; // For date formatting
import 'notification_screen.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:fl_chart/fl_chart.dart';
import 'package:table_calendar/table_calendar.dart';

// Color palette
const deepRed = Color(0xFFB82132);
const coral = Color(0xFFD2665A);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

class PetProfileScreen extends StatefulWidget {
  final Map<String, dynamic>? initialPet;
  PetProfileScreen({Key? key, this.initialPet}) : super(key: key);

  @override
  _PetProfileScreenState createState() => _PetProfileScreenState();
}

class _PetProfileScreenState extends State<PetProfileScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final user = Supabase.instance.client.auth.currentUser;

  List<Map<String, dynamic>> _pets = [];
  Map<String, dynamic>? _selectedPet;

  // loading flag to know when we've finished fetching pets
  bool _loadingPets = true;

  String backendUrl = "http://192.168.100.23:5000/analyze"; // set to your deployed backend
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

  // illness risk returned by backend (high/low/null)
  String? _illnessRisk;
  // numeric sleep forecast (7 days) returned by backend
  List<double> _backendSleepForecast = [];

  final List<String> moods = [
    "Happy", "Anxious", "Aggressive", "Calm", "Lethargic"
  ];

  final List<String> activityLevels = ["High", "Medium", "Low"];

  // Add these variables
  CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  // map of date -> list of event markers (used by TableCalendar)
  Map<DateTime, List<String>> _events = {};
  // list of recent prediction records fetched from Supabase
  List<Map<String, dynamic>> _recentPredictions = [];

  // emoji mappings for mood & activity
  final Map<String, String> _moodEmojis = {
    'Happy': '😄',
    'Anxious': '😟',
    'Aggressive': '😠',
    'Calm': '😌',
    'Lethargic': '😴',
  };
  final Map<String, String> _activityEmojis = {
    'High': '🏃',
    'Medium': '🚶',
    'Low': '🛋️',
  };

  late TextEditingController _sleepController;

  Future<Map<String, dynamic>?> _fetchLatestPet() async {
    final ownerId = user?.id;
    if (ownerId == null) return null;
    final response = await Supabase.instance.client
        .from('pets')
        .select()
        .eq('owner_id', ownerId)
        .order('id', ascending: false)
        .limit(1);
    final data = response as List?;
    if (data == null || data.isEmpty) return null;
    return data.first as Map<String, dynamic>;
  }

  Future<void> _fetchPets() async {
    final ownerId = user?.id;
    if (ownerId == null) {
      setState(() => _loadingPets = false);
      return;
    }

    setState(() => _loadingPets = true);
    try {
      final response = await Supabase.instance.client
          .from('pets')
          .select()
          .eq('owner_id', ownerId)
          .order('id', ascending: false);
      final data = response as List?;
      if (data != null && data.isNotEmpty) {
        final list = List<Map<String, dynamic>>.from(data);
        Map<String, dynamic>? selected;
        // prefer widget.initialPet if provided (match by id), otherwise pick first
        if (widget.initialPet != null) {
          final initId = widget.initialPet!['id'];
          try {
            selected = list.firstWhere((p) => p['id'] == initId, orElse: () => widget.initialPet!);
          } catch (_) {
            selected = widget.initialPet;
          }
        } else {
          selected = list.first;
        }
        setState(() {
          _pets = list;
          _selectedPet = selected;
          // stop showing loader as soon as we have pet data
          _loadingPets = false;
        });
        // Trigger additional fetches in background so UI can render immediately.
        // We intentionally do NOT await these so they don't keep the loader visible.
        _fetchBehaviorDates();
        _fetchRecentPredictions();
        _fetchAnalyzeFromBackend();
        _fetchLatestAnalysis();
      } else {
        // no pets found
        setState(() {
          _pets = [];
          _selectedPet = null;
          _loadingPets = false;
        });
      }
    } catch (e) {
      // ensure loader is cleared on error
      setState(() => _loadingPets = false);
    }
  }

  Future<void> _fetchLatestAnalysis() async {
    if (_selectedPet == null) return;
    final petId = _selectedPet!['id'];
    final response = await Supabase.instance.client
        .from('predictions')
        .select()
        .eq('pet_id', petId)
        .order('created_at', ascending: false)
        .limit(1);

    final data = response as List?;
    if (data != null && data.isNotEmpty) {
      final analysis = data.first as Map<String, dynamic>;
      setState(() {
        _prediction = analysis['prediction'];
        _recommendation = analysis['recommendation'];
        final trends = analysis['trends'] ?? {};
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
    }

    // also refresh calendar markers and recent predictions
    await _fetchBehaviorDates();
    await _fetchRecentPredictions();
  }

  // fetch behavior log dates for the selected pet and populate _events with a marker
  Future<void> _fetchBehaviorDates() async {
    if (_selectedPet == null) return;
    try {
      final petId = _selectedPet!['id'];
      final response = await Supabase.instance.client
          .from('behavior_logs')
          .select('log_date')
          .eq('pet_id', petId)
          .order('log_date', ascending: true);
      final data = response as List? ?? [];
      final Map<DateTime, List<String>> map = {};
      for (final row in data) {
        try {
          final raw = row['log_date']?.toString();
          if (raw == null) continue;
          final dt = DateTime.parse(raw);
          final key = DateTime(dt.year, dt.month, dt.day);
          map.putIfAbsent(key, () => []).add('🐾'); // use paw emoji as sticker
        } catch (_) {
          // ignore parse errors
        }
      }
      setState(() {
        _events = map;
      });
    } catch (e) {
      // ignore / optionally log
    }
  }

  // fetch recent predictions (latest 5) for the selected pet
  Future<void> _fetchRecentPredictions() async {
    if (_selectedPet == null) return;
    try {
      final petId = _selectedPet!['id'];
      final response = await Supabase.instance.client
          .from('predictions')
          .select()
          .eq('pet_id', petId)
          .order('prediction_date', ascending: false)
          .limit(5);
      final data = response as List? ?? [];
      setState(() {
        _recentPredictions = List<Map<String, dynamic>>.from(data);
      });
    } catch (e) {
      // ignore / optionally log
    }
  }

  // Call backend /analyze to get illness risk and numeric sleep forecast (and analysis summary).
  Future<void> _fetchAnalyzeFromBackend() async {
    if (_selectedPet == null) return;
    try {
      final resp = await http.post(
        Uri.parse(backendUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'pet_id': _selectedPet!['id']}),
      );
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        // backend keys: "trend" / "recommendation" / "sleep_forecast" (numeric) / "illness_risk"
        setState(() {
          _prediction = (body['trend'] ?? body['prediction_text'] ?? body['prediction'])?.toString();
          _recommendation = (body['recommendation'] ?? body['suggestions'])?.toString();
          // numeric sleep forecast (list)
          final sf = body['sleep_forecast'];
          if (sf is List) {
            _backendSleepForecast = sf.map((e) => (e as num).toDouble()).toList();
            _sleepTrend = _backendSleepForecast; // use for chart
          }
          // mood/activity prob: backend may return dicts
          final moodProb = body['mood_prob'] ?? body['mood_probabilities'];
          final actProb = body['activity_prob'] ?? body['activity_probabilities'];
          if (moodProb is Map) {
            _moodProb = moodProb.map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));
          }
          if (actProb is Map) {
            _activityProb = actProb.map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));
          }
          _illnessRisk = body['illness_risk']?.toString();
        });
      } else {
        // non-200 response: ignore for now
      }
    } catch (e) {
      // ignore network errors silently or log
    }
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _sleepController = TextEditingController();
    _fetchPets();
  }

  @override
  void dispose() {
    _sleepController.dispose();
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
            onSelected: (pet) async {
              setState(() {
                _selectedPet = pet;
              });
              // update calendar markers and recent predictions right away
              await _fetchBehaviorDates();
              await _fetchRecentPredictions();
              // fetch backend analysis (illness risk + numeric sleep forecast) immediately
              await _fetchAnalyzeFromBackend();
              await _fetchLatestAnalysis();
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
      body: _loadingPets
          ? Center(child: CircularProgressIndicator(color: deepRed))
          : _pets.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Text(
                      'No pet. Go to the profile to add a pet',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: deepRed),
                    ),
                  ),
                )
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
                                Icon(Icons.favorite, color: _illnessRisk != null ? deepRed : Colors.green),
                                SizedBox(height: 4),
                                Text('Health',
                                    style: TextStyle(fontWeight: FontWeight.bold)),
                                Text(_illnessRisk != null ? 'Bad' : 'Good',
                                    style: TextStyle(color: _illnessRisk != null ? deepRed : Colors.green)),
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
                            // Use a responsive height to avoid overflow; allow behavior tab to scroll
                            Container(
                              height: MediaQuery.of(context).size.height * 0.55,
                              padding: EdgeInsets.all(12),
                              child: TabBarView(
                                controller: _tabController,
                                children: [
                                  _buildTabContent('QR Code Content Here'),
                                  _buildTabContent('Location Content Here'),
                                  _buildBehaviorTab(), // Updated Behavior Tab (scrollable)
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
    // Make the behavior tab scrollable to prevent RenderFlex overflow
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0),
        child: Column(
          children: [
            TableCalendar(
              firstDay: DateTime.utc(2020, 1, 1),
              lastDay: DateTime.utc(2030, 12, 31),
              focusedDay: _focusedDay,
              calendarFormat: _calendarFormat,
              // restrict to 1-month view and hide format button
              availableCalendarFormats: const { CalendarFormat.month: 'month' },
              headerStyle: HeaderStyle(formatButtonVisible: false),
              selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
              // supply events from behavior logs
              eventLoader: (day) {
                final key = DateTime(day.year, day.month, day.day);
                return _events[key] ?? [];
              },
              calendarBuilders: CalendarBuilders(
                markerBuilder: (context, date, events) {
                  if (events.isNotEmpty) {
                    return Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 4.0),
                        child: Text(
                          events.join(' '), // show emoji(s)
                          style: TextStyle(fontSize: 16),
                        ),
                      ),
                    );
                  }
                  return SizedBox.shrink();
                },
              ),
              onDaySelected: (selectedDay, focusedDay) {
                setState(() {
                  _selectedDay = selectedDay;
                  _focusedDay = focusedDay;
                  _selectedDate = selectedDay; // ensure modal/save uses tapped date
                });
                _showBehaviorModal(context, selectedDay);
              },
              onFormatChanged: (format) {
                setState(() {
                  _calendarFormat = format;
                });
              },
            ),
            SizedBox(height: 12),
            // Recent predictions list (fetched from Supabase)
            // show recent predictions only when there is NOT a latest analysis
            if (_prediction == null && _recentPredictions.isNotEmpty) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0),
                  child: Text("Recent Predictions",
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              SizedBox(height: 8),
              ListView.builder(
                shrinkWrap: true,
                physics: NeverScrollableScrollPhysics(),
                itemCount: _recentPredictions.length,
                itemBuilder: (context, idx) {
                  final p = _recentPredictions[idx];
                  final date = p['prediction_date']?.toString() ?? '';
                  final text = p['prediction_text'] ?? p['trend'] ?? '';
                  final suggest = p['suggestions'] ?? p['recommendations'] ?? '';
                  return Card(
                    margin: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      title: Text(text, style: TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(suggest.toString()),
                      trailing: Text(
                        date,
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ),
                  );
                },
              ),
            ],
            // Always show illness status: risk if present, otherwise a healthy message
            SizedBox(height: 12),
            Container(
              margin: EdgeInsets.symmetric(horizontal: 16),
              padding: EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
              ),
              child: Row(
                children: [
                  Icon(_illnessRisk != null ? Icons.health_and_safety : Icons.check_circle,
                      color: _illnessRisk != null ? deepRed : Colors.green),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _illnessRisk != null
                          ? "Illness risk: ${_illnessRisk}"
                          : "No illness predicted — pet appears healthy",
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
            if (_prediction != null) ...[
              SizedBox(height: 16),
              Container(
                margin: EdgeInsets.symmetric(horizontal: 16),
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Latest Analysis",
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    SizedBox(height: 8),
                    Text("Prediction: $_prediction"),
                    SizedBox(height: 4),
                    Text("Recommendation: $_recommendation"),
                    if (_backendSleepForecast.isNotEmpty) ...[
                      SizedBox(height: 8),
                      Text("Sleep forecast (hrs): ${_backendSleepForecast.map((d) => d.toStringAsFixed(1)).join(', ')}",
                        style: TextStyle(fontSize: 12, color: Colors.grey[700])),
                    ],
                  ],
                ),
              ),

             // Chart + distributions (moved from modal) — appears after predictions
             if (_sleepTrend.isNotEmpty) ...[
               SizedBox(height: 12),
               Container(
                 margin: EdgeInsets.symmetric(horizontal: 16),
                 padding: EdgeInsets.all(12),
                 decoration: BoxDecoration(
                   color: Colors.white,
                   borderRadius: BorderRadius.circular(8),
                   boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
                 ),
                 child: Column(
                   crossAxisAlignment: CrossAxisAlignment.start,
                   children: [
                     Text("7-day Sleep Forecast", style: TextStyle(fontWeight: FontWeight.bold)),
                     SizedBox(height: 8),
                     SizedBox(
                       height: 180,
                       child: LineChart(
                         LineChartData(
                           minY: 0,
                           maxY: 24,
                           titlesData: FlTitlesData(
                             leftTitles: AxisTitles(
                               sideTitles: SideTitles(showTitles: true),
                             ),
                             bottomTitles: AxisTitles(
                               sideTitles: SideTitles(
                                 showTitles: true,
                                 getTitlesWidget: (value, meta) {
                                   int idx = value.toInt();
                                   if (idx >= 0 && idx < _sleepTrend.length) {
                                     final date = _selectedDate != null
                                         ? _selectedDate!.add(Duration(days: idx))
                                         : DateTime.now().add(Duration(days: idx));
                                     return Text(DateFormat('MM/dd').format(date), style: TextStyle(fontSize: 10));
                                   }
                                   return Text('');
                                 },
                               ),
                             ),
                           ),
                           gridData: FlGridData(show: true),
                           borderData: FlBorderData(show: true),
                           lineBarsData: [
                             LineChartBarData(
                               spots: List.generate(
                                 _sleepTrend.length,
                                 (i) => FlSpot(i.toDouble(), _sleepTrend[i]),
                               ),
                               isCurved: true,
                               dotData: FlDotData(show: true),
                               belowBarData: BarAreaData(show: true),
                               barWidth: 3,
                               color: deepRed,
                             ),
                           ],
                         ),
                       ),
                     ),
                     SizedBox(height: 12),
                     Text("Mood distribution (recent):", style: TextStyle(fontWeight: FontWeight.bold)),
                     SizedBox(height: 6),
                     Text(_moodProb.isEmpty
                         ? "No mood data"
                         : _moodProb.entries.map((e) => "${e.key}: ${(e.value * 100).round()}%").join("  ·  ")),
                     SizedBox(height: 8),
                     Text("Activity distribution (recent):", style: TextStyle(fontWeight: FontWeight.bold)),
                     SizedBox(height: 6),
                     Text(_activityProb.isEmpty
                         ? "No activity data"
                         : _activityProb.entries.map((e) => "${e.key}: ${(e.value * 100).round()}%").join("  ·  ")),
                   ],
                 ),
               ),
             ],
          ],
          ],
        ),
      ),
    );
  }

  void _showBehaviorModal(BuildContext context, DateTime selectedDate) {
    // ensure controller shows current value when modal opens
    _sleepController.text = _sleepHours != null ? _sleepHours.toString() : '';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.8,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    DateFormat('MMMM d, yyyy').format(selectedDate),
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    icon: Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              Divider(),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Mood", style: TextStyle(fontWeight: FontWeight.bold)),
                      SizedBox(height: 8),
                      // emoji picker for mood
                      Wrap(
                        spacing: 8,
                        children: moods.map((mood) {
                          final emoji = _moodEmojis[mood] ?? '•';
                          final selected = _selectedMood == mood;
                          return GestureDetector(
                            onTap: () => setState(() => _selectedMood = mood),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: selected ? deepRed.withOpacity(0.12) : Colors.white,
                                    border: Border.all(color: selected ? deepRed : Colors.grey.shade300),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(emoji, style: TextStyle(fontSize: 26)),
                                ),
                                SizedBox(height: 6),
                                Text(mood, style: TextStyle(fontSize: 12)),
                              ],
                            ),
                          );
                        }).toList(),
                      ),

                      SizedBox(height: 16),

                      // Activity Level Dropdown
                      Text("Activity Level", style: TextStyle(fontWeight: FontWeight.bold)),
                      SizedBox(height: 8),
                      // emoji picker for activity
                      Wrap(
                        spacing: 8,
                        children: activityLevels.map((level) {
                          final emoji = _activityEmojis[level] ?? '•';
                          final selected = _activityLevel == level;
                          return GestureDetector(
                            onTap: () => setState(() => _activityLevel = level),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: selected ? deepRed.withOpacity(0.12) : Colors.white,
                                    border: Border.all(color: selected ? deepRed : Colors.grey.shade300),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(emoji, style: TextStyle(fontSize: 26)),
                                ),
                                SizedBox(height: 6),
                                Text(level, style: TextStyle(fontSize: 12)),
                              ],
                            ),
                          );
                        }).toList(),
                      ),

                      SizedBox(height: 16),

                      // Sleep Hours
                      Text("Sleep Hours", style: TextStyle(fontWeight: FontWeight.bold)),
                      SizedBox(height: 8),
                      // Text field with up/down buttons
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _sleepController,
                              keyboardType: TextInputType.numberWithOptions(decimal: true),
                              decoration: InputDecoration(
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                filled: true,
                                fillColor: Colors.white,
                                hintText: "Enter sleep hours (0 - 24)",
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                              ),
                              onChanged: (value) {
                                setState(() {
                                  final parsed = double.tryParse(value);
                                  if (parsed == null || parsed < 0) {
                                    _sleepHours = null;
                                  } else if (parsed > 24) {
                                    _sleepHours = 24;
                                    _sleepController.text = "24";
                                    _sleepController.selection = TextSelection.fromPosition(TextPosition(offset: _sleepController.text.length));
                                  } else {
                                    _sleepHours = parsed;
                                  }
                                });
                              },
                            ),
                          ),
                          SizedBox(width: 8),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: IconButton(
                                  icon: Icon(Icons.arrow_drop_up),
                                  onPressed: () {
                                    setState(() {
                                      final current = _sleepHours ?? double.tryParse(_sleepController.text) ?? 0.0;
                                      final next = (current + 0.5).clamp(0.0, 24.0);
                                      _sleepHours = double.parse(next.toStringAsFixed(1));
                                      _sleepController.text = _sleepHours.toString();
                                    });
                                  },
                                ),
                              ),
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: IconButton(
                                  icon: Icon(Icons.arrow_drop_down),
                                  onPressed: () {
                                    setState(() {
                                      final current = _sleepHours ?? double.tryParse(_sleepController.text) ?? 0.0;
                                      final next = (current - 0.5).clamp(0.0, 24.0);
                                      _sleepHours = double.parse(next.toStringAsFixed(1));
                                      _sleepController.text = _sleepHours.toString();
                                    });
                                  },
                                ),
                              ),
                            ],
                          ),
                        ],
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

                                    // Close the modal after successful save
                                    Navigator.of(context).pop();
                                    // Refresh calendar markers and recent predictions
                                    await _fetchBehaviorDates();
                                    await _fetchRecentPredictions();

                                    // 2) Call backend analyze endpoint
                                    try {
                                      final resp = await http.post(
                                        Uri.parse("http://192.168.100.23:5000/analyze"),
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

                                       if (mounted) ScaffoldMessenger.of(this.context).showSnackBar(
                                         SnackBar(content: Text('Behavior logged and analyzed!')),

                                       );
                                      } else {
                                       if (mounted) ScaffoldMessenger.of(this.context).showSnackBar(
                                         SnackBar(content: Text('Analysis unavailable (status ${resp.statusCode})')),
                                       );
                                      }
                                    } catch (e) {
                                     if (mounted) ScaffoldMessenger.of(this.context).showSnackBar(
                                      SnackBar(content: Text('Analysis failed: $e')),
                                     );
                                    }
                                  } on PostgrestException catch (e) {
                                   if (mounted) ScaffoldMessenger.of(this.context).showSnackBar(
                                      SnackBar(content: Text('Failed to save log: ${e.message}')),
                                   );
                                  } catch (e) {
                                   if (mounted) ScaffoldMessenger.of(this.context).showSnackBar(
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
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}