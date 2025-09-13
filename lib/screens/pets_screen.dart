import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart'; // For date formatting
import 'notification_screen.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:fl_chart/fl_chart.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:qr_flutter/qr_flutter.dart' as qr_flutter;
import 'package:flutter/services.dart'; // for Clipboard
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

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
  bool _isUnhealthy = false; // <-- add
  List<String> _careActions = [];        // <-- add
  List<String> _careExpectations = [];   // <-- add

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
        // We intentionally do NOT await these so they don't keep the loader visible
        _fetchBehaviorDates();
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
      // Safely read DB fields; only assign if present
      final pred = (analysis['prediction_text'] ?? analysis['prediction'] ?? analysis['trend'])?.toString();
      final rec = (analysis['suggestions'] ?? analysis['recommendation'])?.toString();
      final trends = analysis['trends'] as Map<String, dynamic>?; // may be absent

      setState(() {
        if (pred != null && pred.isNotEmpty) {
          _prediction = pred;
        }
        if (rec != null && rec.isNotEmpty) {
          _recommendation = rec;
        }
        if (trends != null) {
          _sleepTrend = (trends['sleep_forecast'] as List<dynamic>?)
                  ?.map((e) => (e as num).toDouble())
                  .toList() ??
              _sleepTrend; // keep existing if missing
          _moodProb = (trends['mood_probabilities'] as Map?)
                  ?.map((k, v) => MapEntry(k.toString(), (v as num).toDouble())) ??
              _moodProb;
          _activityProb = (trends['activity_probabilities'] as Map?)
                  ?.map((k, v) => MapEntry(k.toString(), (v as num).toDouble())) ??
              _activityProb;
        }
      });
    }

    // also refresh calendar markers
    await _fetchBehaviorDates();
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
        setState(() {
          _prediction = (body['trend'] ?? body['prediction_text'] ?? body['prediction'])?.toString();
          _recommendation = (body['recommendation'] ?? body['suggestions'])?.toString();
          final sf = body['sleep_forecast'];
          if (sf is List) {
            _backendSleepForecast = sf.map((e) => (e as num).toDouble()).toList();
            _sleepTrend = _backendSleepForecast;
          }
          final moodProb = body['mood_prob'] ?? body['mood_probabilities'];
          final actProb = body['activity_prob'] ?? body['activity_probabilities'];
          if (moodProb is Map) {
            _moodProb = moodProb.map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));
          }
          if (actProb is Map) {
            _activityProb = actProb.map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));
          }
          final riskRaw = body['illness_risk']?.toString().toLowerCase();
          _illnessRisk = riskRaw;
          final unhealthyResp = body['is_unhealthy'];
          _isUnhealthy = unhealthyResp is bool
              ? unhealthyResp
              : (riskRaw == 'high' || riskRaw == 'medium');

          // parse care recommendations
          _careActions = [];
          _careExpectations = [];
          final care = body['care_recommendations'];
          if (care is Map) {
            final a = care['actions'];
            final e = care['expectations'];
            if (a is List) {
              _careActions = a.map((x) => x.toString()).where((s) => s.isNotEmpty).toList();
            }
            if (e is List) {
              _careExpectations = e.map((x) => x.toString()).where((s) => s.isNotEmpty).toList();
            }
          }
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

  void _showBluetoothConnectionModal(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.bluetooth, color: deepRed),
              SizedBox(width: 8),
              Text('GPS Device Connection'),
            ],
          ),
          content: Container(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Follow these steps to connect your GPS device:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                SizedBox(height: 16),
                _buildConnectionStep(
                  '1',
                  'Enable Bluetooth',
                  'Make sure Bluetooth is enabled on your device',
                  Icons.bluetooth_connected,
                ),
                SizedBox(height: 12),
                _buildConnectionStep(
                  '2',
                  'Turn on GPS Device',
                  'Power on your pet\'s GPS tracking device',
                  Icons.power_settings_new,
                ),
                SizedBox(height: 12),
                _buildConnectionStep(
                  '3',
                  'Open Bluetooth Settings',
                  'Go to your device\'s Bluetooth settings to pair',
                  Icons.settings,
                ),
                SizedBox(height: 12),
                _buildConnectionStep(
                  '4',
                  'Scan & Pair',
                  'Look for your GPS device and tap to pair',
                  Icons.search,
                ),
                SizedBox(height: 16),
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: lightBlush,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: coral, width: 1),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info, color: deepRed, size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Make sure your GPS device is in pairing mode before scanning.',
                          style: TextStyle(color: deepRed, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                _openBluetoothSettings();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: deepRed,
                foregroundColor: Colors.white,
              ),
              child: Text('Open Bluetooth Settings'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildConnectionStep(String number, String title, String description, IconData icon) {
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: deepRed,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              number,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
        ),
        SizedBox(width: 12),
        Icon(icon, color: coral, size: 20),
        SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              Text(
                description,
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _openBluetoothSettings() {
    // This would typically open the device's Bluetooth settings
    // For now, we'll show a message
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.bluetooth, color: Colors.white),
            SizedBox(width: 8),
            Text('Please open your device\'s Bluetooth settings to pair with GPS device'),
          ],
        ),
        backgroundColor: deepRed,
        duration: Duration(seconds: 3),
        action: SnackBarAction(
          label: 'OK',
          textColor: Colors.white,
          onPressed: () {},
        ),
      ),
    );
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
          IconButton(
            icon: Icon(Icons.bluetooth),
            onPressed: () {
              _showBluetoothConnectionModal(context);
            },
          ),
          PopupMenuButton<Map<String, dynamic>>(
            icon: Icon(Icons.more_vert),
            onSelected: (pet) async {
              setState(() {
                _selectedPet = pet;
              });
              // update calendar markers right away
              await _fetchBehaviorDates();
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
                                Icon(Icons.favorite, color: _isUnhealthy ? deepRed : Colors.green),
                                SizedBox(height: 4),
                                Text('Health', style: TextStyle(fontWeight: FontWeight.bold)),
                                Text(_isUnhealthy ? 'Bad' : 'Good',
                                    style: TextStyle(color: _isUnhealthy ? deepRed : Colors.green)),
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
                      // Action button for missing/lost status
                      if (_selectedPet != null && _selectedPet!['is_missing'] == true) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: deepRed,
                              minimumSize: Size(double.infinity, 48),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: Icon(Icons.pets, color: Colors.white),
                            label: Text('Mark as Found', style: TextStyle(color: Colors.white)),
                            onPressed: () async {
                              try {
                                await Supabase.instance.client
                                    .from('pets')
                                    .update({'is_missing': false})
                                    .eq('id', _selectedPet!['id']);
                                setState(() {
                                  _selectedPet!['is_missing'] = false;
                                });
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Pet marked as found!')),
                                  );
                                }
                              } catch (e) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Failed to update: $e')),
                                  );
                                }
                              }
                            },
                          ),
                        ),
                        SizedBox(height: 8),
                      ] else if (_selectedPet != null && (_selectedPet!['is_missing'] == false || _selectedPet!['is_missing'] == null)) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange,
                              minimumSize: Size(double.infinity, 48),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: Icon(Icons.report, color: Colors.white),
                            label: Text('Mark as Missing/Lost', style: TextStyle(color: Colors.white)),
                            onPressed: () async {
                              try {
                                await Supabase.instance.client
                                    .from('pets')
                                    .update({'is_missing': true})
                                    .eq('id', _selectedPet!['id']);
                                setState(() {
                                  _selectedPet!['is_missing'] = true;
                                });
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Pet marked as missing/lost!')),
                                  );
                                }
                              } catch (e) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Failed to update: $e')),
                                  );
                                }
                              }
                            },
                          ),
                        ),
                        SizedBox(height: 8),
                      ],
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
                                  _buildQRCodeSection(), // show per-pet QR
                                  _buildLocationTab(), // <-- use map here
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

  Widget _buildLocationTab() {
    double? lat, lng;
    Widget markerWidget = Icon(Icons.location_pin, color: deepRed, size: 40);

    if (_selectedPet != null &&
        _selectedPet!['latitude'] != null &&
        _selectedPet!['longitude'] != null) {
      lat = double.tryParse(_selectedPet!['latitude'].toString());
      lng = double.tryParse(_selectedPet!['longitude'].toString());
      markerWidget = CircleAvatar(
        radius: 20,
        backgroundColor: Colors.white,
        child: Image.asset('assets/pets-profile-pictures.png', width: 32, height: 32, fit: BoxFit.cover),
      );
    }

    // Agusan del Norte coordinates
    final agusanDelNorteCenter = LatLng(9.0, 125.5);

    final mapCenter = (lat != null && lng != null)
        ? LatLng(lat, lng)
        : agusanDelNorteCenter;

    return FlutterMap(
      options: MapOptions(
        initialCenter: mapCenter,
        initialZoom: 11,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
          subdomains: const ['a', 'b', 'c'],
        ),
        if (lat != null && lng != null)
          MarkerLayer(
            markers: [
              Marker(
                point: LatLng(lat, lng),
                width: 40,
                height: 40,
                child: markerWidget,
              ),
            ],
          ),
      ],
    );
  }

  // generate PNG bytes for the QR using qr_flutter's QrPainter
  Future<Uint8List?> _generateQrBytes(String data, double size) async {
    try {
      final painter = qr_flutter.QrPainter(
        data: data,
        version: qr_flutter.QrVersions.auto,
        gapless: false,
        color: Colors.black,
        emptyColor: Colors.white,
      );
      final byteData = await painter.toImageData(size);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      // return null on failure
      return null;
    }
  }

  Widget _buildQRCodeSection() {
    final ownerMeta = Supabase.instance.client.auth.currentUser?.userMetadata ?? {};
    final ownerName = ownerMeta['name']?.toString() ?? Supabase.instance.client.auth.currentUser?.email ?? 'Owner';

    if (_selectedPet == null) {
      return _buildTabContent('No pet selected');
    }

    // Build a public URL that opens the pet info page (works even without the app)
    final baseBackend = backendUrl.replaceAll(RegExp(r'/analyze/?\$'), '');
    final publicUrl = '$baseBackend/pet/${_selectedPet!['id']}';
    final payloadStr = publicUrl;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('Scan to view pet info', style: TextStyle(fontWeight: FontWeight.bold, color: deepRed)),
          SizedBox(height: 12),
          Container(
            color: Colors.white,
            padding: EdgeInsets.all(12),
            // generate QR bytes and show Image.memory (works across qr_flutter versions)
            child: FutureBuilder<Uint8List?>(
              future: _generateQrBytes(payloadStr, 220.0),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return SizedBox(width: 220, height: 220, child: Center(child: CircularProgressIndicator(color: deepRed)));
                }
                if (snapshot.hasData && snapshot.data != null) {
                  return Image.memory(snapshot.data!, width: 220, height: 220, fit: BoxFit.contain);
                }
                return SizedBox(
                  width: 220,
                  height: 220,
                  child: Center(child: Text('QR unavailable', style: TextStyle(color: Colors.grey))),
                );
              },
            ),
          ),
          SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Text(
              'Owner: $ownerName\nPet: ${_selectedPet!['name'] ?? 'Unnamed'}\n\nScan opens: $publicUrl',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[800]),
            ),
          ),
          SizedBox(height: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton.icon(
                icon: Icon(Icons.copy),
                label: Text('Copy URL'),
                style: ElevatedButton.styleFrom(backgroundColor: deepRed),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: payloadStr));
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Public URL copied to clipboard')));
                },
              ),
              SizedBox(width: 8),
              ElevatedButton.icon(
                icon: Icon(Icons.refresh),
                label: Text('Regenerate'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.grey.shade600),
                onPressed: () {
                  // forces UI refresh (in case pet changed externally)
                  setState(() {});
                },
              ),
            ],
          ),
          SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32.0),
            child: Text(
              'When scanned, the QR contains the pet details and owner name as JSON.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ),
        ],
      ),
    );
  }

  // Fetch behavior log for a specific date (returns the latest if multiple exist)
  Future<Map<String, dynamic>?> _fetchBehaviorForDate(DateTime day) async {
    if (_selectedPet == null) return null;
    try {
      final petId = _selectedPet!['id'];
      final ymd = DateFormat('yyyy-MM-dd').format(day);
      final response = await Supabase.instance.client
          .from('behavior_logs')
          .select()
          .eq('pet_id', petId)
          .eq('log_date', ymd)
          .order('id', ascending: false) // pick latest if multiple
          .limit(1);
      final data = response as List?;
      if (data != null && data.isNotEmpty) {
        return Map<String, dynamic>.from(data.first as Map);
      }
    } catch (_) {}
    return null;
  }

  void _clearBehaviorForm() {
    setState(() {
      _selectedMood = null;
      _activityLevel = null;
      _sleepHours = null;
      _notes = null;
      _sleepController.text = '';
    });
  }

  // Read-only modal showing existing behavior with Edit/Delete
  void _showExistingBehaviorModal(BuildContext context, Map<String, dynamic> log) {
    final mood = (log['mood'] ?? '').toString();
    final activity = (log['activity_level'] ?? '').toString();
    final sleep = (log['sleep_hours'] ?? '').toString();
    final notes = (log['notes'] ?? '').toString();
    final rawDate = (log['log_date'] ?? '').toString();
    DateTime date;
    try {
      date = DateTime.parse(rawDate);
    } catch (_) {
      date = _selectedDate ?? DateTime.now();
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.6,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    DateFormat('MMMM d, yyyy').format(date),
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    icon: Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              Divider(),
              // Details
              ListTile(
                dense: true,
                title: Text('Mood', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(mood.isEmpty ? '-' : mood),
              ),
              ListTile(
                dense: true,
                title: Text('Activity Level', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(activity.isEmpty ? '-' : activity),
              ),
              ListTile(
                dense: true,
                title: Text('Sleep Hours', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(sleep.isEmpty ? '-' : sleep),
              ),
              if (notes.isNotEmpty)
                ListTile(
                  dense: true,
                  title: Text('Notes', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(notes),
                ),
              Spacer(),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: Icon(Icons.edit, color: deepRed),
                      label: Text('Edit', style: TextStyle(color: deepRed)),
                      onPressed: () {
                        Navigator.pop(context); // close details
                        // preload form state then open edit modal
                        setState(() {
                          _selectedDate = date;
                          _selectedMood = mood.isNotEmpty ? mood : null;
                          _activityLevel = activity.isNotEmpty ? activity : null;
                          _sleepHours = double.tryParse(sleep);
                          _sleepController.text = _sleepHours?.toString() ?? '';
                          _notes = notes.isNotEmpty ? notes : null;
                        });
                        _showBehaviorModal(context, date, existing: log);
                      },
                    ),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: deepRed),
                      icon: Icon(Icons.delete, color: Colors.white),
                      label: Text('Delete', style: TextStyle(color: Colors.white)),
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text('Delete entry?'),
                            content: Text('This will remove the behavior log for this day.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel')),
                              TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Delete')),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          try {
                            await Supabase.instance.client
                                .from('behavior_logs')
                                .delete()
                                .eq('id', log['id']);
                            if (mounted) Navigator.pop(context); // close bottom sheet
                            // Refresh events and analysis
                            await _fetchBehaviorDates();
                            await _fetchAnalyzeFromBackend();
                            await _fetchLatestAnalysis();
                            if (mounted) {
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(content: Text('Behavior deleted')),
                              );
                            }
                          } catch (e) {
                            if (mounted) {
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(content: Text('Delete failed: $e')),
                              );
                            }
                          }
                        }
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBehaviorTab() {
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
              onDaySelected: (selectedDay, focusedDay) async {
                setState(() {
                  _selectedDay = selectedDay;
                  _focusedDay = focusedDay;
                  _selectedDate = selectedDay;
                });
                // If there's already a log on this date, show it instead of allowing another insert
                final existingLog = await _fetchBehaviorForDate(selectedDay);
                if (existingLog != null) {
                  _showExistingBehaviorModal(context, existingLog);
                } else {
                  _clearBehaviorForm();
                  _showBehaviorModal(context, selectedDay);
                }
              },
              onFormatChanged: (format) {
                setState(() {
                  _calendarFormat = format;
                });
              },
            ),
            SizedBox(height: 12),
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
                  Icon(_isUnhealthy ? Icons.health_and_safety : Icons.check_circle,
                      color: _isUnhealthy ? deepRed : Colors.green),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _isUnhealthy
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
                      Text(
                        "Sleep forecast (hrs): ${_backendSleepForecast.map((d) => d.toStringAsFixed(1)).join(', ')}",
                        style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                      ),
                    ],
                    // Care Tips (only when risk is bad: medium/high)
                    if (_isUnhealthy && (_careActions.isNotEmpty || _careExpectations.isNotEmpty)) ...[
                      SizedBox(height: 12),
                      Text("Care Tips", style: TextStyle(fontWeight: FontWeight.bold)),
                      if (_careActions.isNotEmpty) ...[
                        SizedBox(height: 6),
                        Text("What to do", style: TextStyle(fontWeight: FontWeight.w600)),
                        ..._careActions.take(6).map((t) => Padding(
                              padding: const EdgeInsets.only(top: 4.0),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text("• "),
                                  Expanded(child: Text(t)),
                                ],
                              ),
                            )),
                      ],
                      if (_careExpectations.isNotEmpty) ...[
                        SizedBox(height: 8),
                        Text("What to expect", style: TextStyle(fontWeight: FontWeight.w600)),
                        ..._careExpectations.take(6).map((t) => Padding(
                              padding: const EdgeInsets.only(top: 4.0),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text("• "),
                                  Expanded(child: Text(t)),
                                ],
                              ),
                            )),
                      ],
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

            // Add a small bottom spacer so the last card isn't flush with the edge
            SizedBox(height: 16),
          ],
          ],
        ),
      ),
    );
  }

  // Extend logging modal to support edit/update when 'existing' is provided
  void _showBehaviorModal(BuildContext context, DateTime selectedDate, {Map<String, dynamic>? existing}) {
    // ensure controller shows current value when modal opens
    _sleepController.text = _sleepHours != null ? _sleepHours.toString() : (_sleepController.text);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isEdit = existing != null && existing['id'] != null;
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
                          icon: Icon(isEdit ? Icons.check : Icons.save, color: Colors.white),
                          label: Text(isEdit ? "Update Behavior" : "Log Behavior", style: TextStyle(color: Colors.white)),
                          onPressed: (_selectedMood == null ||
                                      _selectedDate == null ||
                                      _activityLevel == null ||
                                      _sleepHours == null)
                              ? null
                              : () async {
                                  try {
                                    final payload = {
                                      'pet_id': _selectedPet!['id'],
                                      'user_id': user?.id ?? '',
                                      'log_date': DateFormat('yyyy-MM-dd').format(_selectedDate!),
                                      'notes': _notes,
                                      'mood': _selectedMood,
                                      'sleep_hours': _sleepHours,
                                      'activity_level': _activityLevel,
                                    };
                                    if (isEdit) {
                                      await Supabase.instance.client
                                          .from('behavior_logs')
                                          .update(payload)
                                          .eq('id', existing!['id']);
                                    } else {
                                      await Supabase.instance.client
                                          .from('behavior_logs')
                                          .insert(payload);
                                    }

                                    // Close the modal after successful save
                                    if (mounted) Navigator.of(context).pop();

                                    // Refresh calendar markers
                                    await _fetchBehaviorDates();

                                    // Call backend analyze endpoint to refresh analysis
                                    try {
                                      final resp = await http.post(
                                        Uri.parse("http://192.168.100.23:5000/analyze"),
                                        headers: {'Content-Type': 'application/json'},
                                        body: jsonEncode({
                                          'pet_id': _selectedPet!['id'],
                                          // optional: pass current inputs (not required for /analyze)
                                        }),
                                      );
                                      if (resp.statusCode == 200) {
                                        final body = jsonDecode(resp.body) as Map<String, dynamic>;
                                        setState(() {
                                          _prediction = (body['trend'] ?? body['prediction_text'] ?? body['prediction'])?.toString();
                                          _recommendation = (body['recommendation'] ?? body['suggestions'])?.toString();
                                          final sf = body['sleep_forecast'];
                                          if (sf is List) {
                                            _backendSleepForecast = sf.map((e) => (e as num).toDouble()).toList();
                                            _sleepTrend = _backendSleepForecast;
                                          }
                                          final moodProb = body['mood_prob'] ?? body['mood_probabilities'];
                                          final actProb = body['activity_prob'] ?? body['activity_probabilities'];
                                          if (moodProb is Map) {
                                            _moodProb = moodProb.map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));
                                          }
                                          if (actProb is Map) {
                                            _activityProb = actProb.map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));
                                          }
                                          final riskRaw = body['illness_risk']?.toString().toLowerCase();
                                          _illnessRisk = riskRaw;
                                          final unhealthyResp = body['is_unhealthy'];
                                          _isUnhealthy = unhealthyResp is bool
                                              ? unhealthyResp
                                              : (riskRaw == 'high' || riskRaw == 'medium');

                                          // care tips
                                          _careActions = [];
                                          _careExpectations = [];
                                          final care = body['care_recommendations'];
                                          if (care is Map) {
                                            final a = care['actions'];
                                            final e = care['expectations'];
                                            if (a is List) {
                                              _careActions = a.map((x) => x.toString()).where((s) => s.isNotEmpty).toList();
                                            }
                                            if (e is List) {
                                              _careExpectations = e.map((x) => x.toString()).where((s) => s.isNotEmpty).toList();
                                            }
                                          }
                                        });
                                      }
                                    } catch (_) {}

                                    if (mounted) {
                                      ScaffoldMessenger.of(this.context).showSnackBar(
                                        SnackBar(content: Text(isEdit ? 'Behavior updated!' : 'Behavior logged and analyzed!')),
                                      );
                                    }
                                  } on PostgrestException catch (e) {
                                    if (mounted) {
                                      ScaffoldMessenger.of(this.context).showSnackBar(
                                        SnackBar(content: Text('Save failed: ${e.message}')),
                                      );
                                    }
                                  } catch (e) {
                                    if (mounted) {
                                      ScaffoldMessenger.of(this.context).showSnackBar(
                                        SnackBar(content: Text('Unexpected error: $e')),
                                      );
                                    }
                                  }
                                },
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