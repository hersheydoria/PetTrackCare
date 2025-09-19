import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart'; // For date formatting
import 'notification_screen.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:fl_chart/fl_chart.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:qr_flutter/qr_flutter.dart' as qr_flutter;
import 'package:flutter/services.dart'; // for Clipboard and HapticFeedback
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'dart:async'; 
import '../services/notification_service.dart';
import '../services/missing_pet_alert_service.dart';

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

  // Helper method to get user role
  String _getUserRole() {
    final metadata = user?.userMetadata ?? {};
    final role = metadata['role']?.toString() ?? 'Pet Owner';
    print('DEBUG: User metadata: $metadata');
    print('DEBUG: User role: $role');
    return role;
  }

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

  // New: latest GPS/device location for selected pet
  LatLng? _latestDeviceLocation;
  DateTime? _latestDeviceTimestamp;
  String? _latestDeviceId;

  // Current map view location (can be different from latest device location)
  LatLng? _currentMapLocation;
  String? _currentMapLabel;
  String? _currentMapSub;

 List<Map<String, dynamic>> _locationHistory = [];

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
    final userId = user?.id;
    if (userId == null) {
      setState(() => _loadingPets = false);
      return;
    }

    setState(() => _loadingPets = true);
    print('DEBUG: Starting _fetchPets for userId: $userId');
    print('DEBUG: User role: ${_getUserRole()}');
    try {
      List<Map<String, dynamic>> list = [];
      
      if (_getUserRole() == 'Pet Sitter') {
        // For Pet Sitters: fetch pets they are assigned to through sitting_jobs
        print('DEBUG: Fetching pets for Pet Sitter with userId: $userId');
        
        // First, get the sitting_jobs with status 'Active' for this sitter
        final sittingJobsResponse = await Supabase.instance.client
            .from('sitting_jobs')
            .select('pet_id, status')
            .eq('sitter_id', userId)
            .eq('status', 'Active');
            
        print('DEBUG: Sitting jobs response: $sittingJobsResponse');
        final sittingJobsData = sittingJobsResponse as List?;
        
        if (sittingJobsData != null && sittingJobsData.isNotEmpty) {
          print('DEBUG: Found ${sittingJobsData.length} active sitting jobs');
          
          // Extract pet IDs
          final petIds = sittingJobsData
              .map((job) => job['pet_id'])
              .where((id) => id != null)
              .toList();
          
          print('DEBUG: Pet IDs from sitting jobs: $petIds');
          
          if (petIds.isNotEmpty) {
            // Now fetch the actual pets using these IDs
            final petsResponse = await Supabase.instance.client
                .from('pets')
                .select()
                .inFilter('id', petIds)
                .order('id', ascending: false);
                
            print('DEBUG: Pets response: $petsResponse');
            final petsData = petsResponse as List?;
            if (petsData != null && petsData.isNotEmpty) {
              list = List<Map<String, dynamic>>.from(petsData);
              print('DEBUG: Found ${list.length} pets for Pet Sitter');
            } else {
              print('DEBUG: No pets found for Pet Sitter');
            }
          } else {
            print('DEBUG: No valid pet IDs found in sitting jobs');
          }
        } else {
          print('DEBUG: No active sitting jobs found for Pet Sitter');
        }
      } else {
        // For Pet Owners: fetch pets they own
        final response = await Supabase.instance.client
            .from('pets')
            .select()
            .eq('owner_id', userId)
            .order('id', ascending: false);
        final data = response as List?;
        if (data != null && data.isNotEmpty) {
          list = List<Map<String, dynamic>>.from(data);
        }
      }
      
      if (list.isNotEmpty) {
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
          // clear any previously shown device/map info so we don't show another pet's data
          _currentMapLocation = null;
          _currentMapLabel = null;
          _currentMapSub = null;
          _latestDeviceId = null;
          _latestDeviceLocation = null;
          _latestDeviceTimestamp = null;
          _locationHistory = [];
          // stop showing loader as soon as we have pet data
          _loadingPets = false;
        });
        // Trigger additional fetches in background so UI can render immediately.
        // We intentionally do NOT await these so they don't keep the loader visible
        _fetchBehaviorDates();
        _fetchAnalyzeFromBackend();
        _fetchLatestAnalysis();
        _fetchLatestLocationForPet(); // <-- fetch latest GPS/device location
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

  Future<void> _fetchLatestLocationForPet() async {
    // Fetch the latest location for the device mapped to the selected pet (if any)
    if (_selectedPet == null) {
      setState(() {
        _latestDeviceLocation = null;
        _latestDeviceTimestamp = null;
        _latestDeviceId = null;
        _locationHistory = [];
      });
      return;
    }

    try {
      final petId = _selectedPet!['id'];
      // 1) find device_id in device_pet_map
      final devResp = await Supabase.instance.client
          .from('device_pet_map')
          .select('device_id')
          .eq('pet_id', petId)
          .limit(1);
      final devList = devResp as List? ?? [];
      final deviceId = devList.isNotEmpty ? devList.first['device_id']?.toString() : null;
      if (deviceId == null || deviceId.isEmpty) {
        setState(() {
          _latestDeviceLocation = null;
          _latestDeviceTimestamp = null;
          _latestDeviceId = null;
          _locationHistory = [];
        });
        return;
      }

    // 2) query latest entry in location_history for that device_mac and this pet_id
    final locResp = await Supabase.instance.client
      .from('location_history')
      .select()
      .eq('device_mac', deviceId)
      .eq('pet_id', petId)
      .order('timestamp', ascending: false)
      .limit(1);
      final locList = locResp as List? ?? [];
      if (locList.isNotEmpty) {
        final row = locList.first as Map<String, dynamic>;
        final lat = double.tryParse(row['latitude']?.toString() ?? '');
        final lng = double.tryParse(row['longitude']?.toString() ?? '');
        DateTime? ts;
        final rawTs = row['timestamp'];
        if (rawTs is String) {
          ts = DateTime.tryParse(rawTs);
        } else if (rawTs is DateTime) {
          ts = rawTs;
        }
        setState(() {
          _latestDeviceId = deviceId;
          _latestDeviceTimestamp = ts;
          _latestDeviceLocation = (lat != null && lng != null) ? LatLng(lat, lng) : null;
        });
  await _fetchLocationHistoryForDevice(deviceId, petId: petId);
      } else {
        // device exists but no location rows yet
        setState(() {
          _latestDeviceId = deviceId;
          _latestDeviceTimestamp = null;
          _latestDeviceLocation = null;
        _locationHistory = [];
        });
        // still attempt to fetch history (will be empty) so UI stays consistent
  await _fetchLocationHistoryForDevice(deviceId, petId: petId);
      }
    } catch (e) {
      // ignore but clear device location on error
      setState(() {
        _latestDeviceLocation = null;
        _latestDeviceTimestamp = null;
        _latestDeviceId = null;
        _locationHistory = [];
      });
    }
  }

   // Fetch recent location_history rows (limit 10) for device and reverse-geocode addresses.
  Future<void> _fetchLocationHistoryForDevice(String deviceId, {required String petId, int limit = 10}) async {
    try {
      final resp = await Supabase.instance.client
          .from('location_history')
          .select()
          .eq('device_mac', deviceId)
          .eq('pet_id', petId)
          .order('timestamp', ascending: false)
          .limit(limit);
      final list = resp as List? ?? [];
      final records = <Map<String, dynamic>>[];
      for (final row in list) {
        try {
          final lat = double.tryParse(row['latitude']?.toString() ?? '');
          final lng = double.tryParse(row['longitude']?.toString() ?? '');
          DateTime? ts;
          final rawTs = row['timestamp'];
          if (rawTs is String) ts = DateTime.tryParse(rawTs);
          else if (rawTs is DateTime) ts = rawTs;
          String? address;
          if (lat != null && lng != null) {
            // try reverse geocoding; non-blocking but awaited so UI gets addresses
            address = await _reverseGeocode(lat, lng);
          }
          records.add({
            'latitude': lat,
            'longitude': lng,
            'timestamp': ts,
            'device_mac': row['device_mac'],
            'address': address,
          });
        } catch (_) {
          // skip malformed row
        }
      }
      setState(() {
        _locationHistory = records;
      });
    } catch (_) {
      setState(() {
        _locationHistory = [];
      });
    }
  }

  // Reverse geocode using Nominatim (OpenStreetMap). Returns display_name or null.
  Future<String?> _reverseGeocode(double lat, double lng) async {
    try {
      final url = Uri.parse('https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=$lat&lon=$lng');
      final resp = await http.get(url, headers: {'User-Agent': 'PetTrackCare/1.0 (+your-email@example.com)'});
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final display = body['display_name'];
        if (display is String && display.isNotEmpty) return display;
      }
    } catch (_) {}
    return null;
  }

  // Refresh addresses for location history items that don't have addresses yet
  Future<void> _refreshAddressesForLocationHistory() async {
    if (_locationHistory.isEmpty) return;
    
    bool hasUpdates = false;
    final updatedHistory = <Map<String, dynamic>>[];
    
    for (final record in _locationHistory) {
      final lat = record['latitude'] as double?;
      final lng = record['longitude'] as double?;
      final currentAddress = record['address'] as String?;
      
      // If no address exists and we have coordinates, try to get address
      if ((currentAddress == null || currentAddress.isEmpty) && lat != null && lng != null) {
        final newAddress = await _reverseGeocode(lat, lng);
        if (newAddress != null && newAddress.isNotEmpty) {
          final updatedRecord = Map<String, dynamic>.from(record);
          updatedRecord['address'] = newAddress;
          updatedHistory.add(updatedRecord);
          hasUpdates = true;
        } else {
          updatedHistory.add(record);
        }
      } else {
        updatedHistory.add(record);
      }
    }
    
    if (hasUpdates) {
      setState(() {
        _locationHistory = updatedHistory;
      });
    }
  }

  String _formatTimestamp(DateTime? dt) {
    if (dt == null) return '-';
    try {
      return DateFormat('MMM d, yyyy • hh:mm a').format(dt.toLocal());
    } catch (_) {
      return dt.toIso8601String();
    }
  }

  // Helper: expand map view to fullscreen
  void _expandMapView() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _FullScreenMapView(
          center: _currentMapLocation ?? _latestDeviceLocation ?? LatLng(9.0, 125.5),
          markerLocation: _currentMapLocation ?? _latestDeviceLocation,
          markerLabel: _currentMapLabel ?? (_latestDeviceLocation != null ? 'Current Location' : null),
          markerSub: _currentMapSub ?? (_latestDeviceTimestamp != null 
            ? DateFormat('MMM d, HH:mm').format(_latestDeviceTimestamp!.toLocal()) 
            : null),
          locationHistory: _locationHistory,
          onLocationSelected: (location, label, subtitle) {
            Navigator.pop(context);
            _updateMapView(location, label, subtitle);
          },
        ),
      ),
    );
  }

  // Helper: update map view to show specific location from history
  void _updateMapView(LatLng location, String label, String subtitle) {
    setState(() {
      _currentMapLocation = location;
      _currentMapLabel = label;
      _currentMapSub = subtitle;
    });
  }

  // Get the actual pet owner's name from the database
  Future<String> _getActualOwnerName() async {
    if (_selectedPet == null) return 'Unknown Owner';
    
    try {
      final ownerId = _selectedPet!['owner_id'];
      if (ownerId == null) return 'Unknown Owner';
      
      // Fetch owner information from users table
      final response = await Supabase.instance.client
          .from('users')
          .select('name')
          .eq('id', ownerId)
          .limit(1);
          
      final userData = response as List?;
      if (userData != null && userData.isNotEmpty) {
        final user = userData.first as Map<String, dynamic>;
        final name = user['name']?.toString();
        
        // Return name if available, otherwise fallback
        return name?.isNotEmpty == true ? name! : 'Owner';
      }
    } catch (e) {
      print('Error fetching owner name: $e');
    }
    
    return 'Owner';
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

  void _showBluetoothConnectionModal(BuildContext context) async {
    // First check if there's already a connected device
    final currentDeviceId = await _getStoredDeviceId();
    
    if (currentDeviceId != null) {
      // Show device status and disconnect option
      _showDeviceStatusModal(context, currentDeviceId);
    } else {
      // Show connection modal
      _showConnectDeviceModal(context);
    }
  }

  void _showDeviceStatusModal(BuildContext context, String deviceId) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.device_hub, color: Colors.green),
              SizedBox(width: 8),
              Text('GPS Device Connected'),
            ],
          ),
          content: Container(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Current connected device:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                SizedBox(height: 12),
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle, color: Colors.green, size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'MAC Address: $deviceId',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Device is actively tracking location',
                              style: TextStyle(color: Colors.green.shade700, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
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
                      Icon(Icons.warning, color: deepRed, size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Disconnecting will stop location tracking for this pet.',
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
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _showConnectDeviceModal(context);
              },
              child: Text('Change Device', style: TextStyle(color: coral)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                _disconnectDevice();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: Text('Disconnect'),
            ),
          ],
        );
      },
    );
  }

  void _showConnectDeviceModal(BuildContext context) {
    final TextEditingController _macController = TextEditingController();
    String? errorMessage;
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Row(
                children: [
                  Icon(Icons.device_hub, color: deepRed),
                  SizedBox(width: 8),
                  Text('Connect GPS Device'),
                ],
              ),
              content: Container(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Enter your GPS tracking device MAC address:',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    SizedBox(height: 16),
                    TextField(
                      controller: _macController,
                      decoration: InputDecoration(
                        labelText: 'Device MAC Address',
                        hintText: 'XX:XX:XX:XX:XX:XX',
                        prefixIcon: Icon(Icons.device_hub, color: coral),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        errorText: errorMessage,
                      ),
                      onChanged: (value) {
                        // Clear error when user starts typing
                        if (errorMessage != null) {
                          setState(() {
                            errorMessage = null;
                          });
                        }
                      },
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
                              'Find the MAC address on your GPS device label or in device settings.',
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
                    final macAddress = _macController.text.trim();
                    if (macAddress.isEmpty) {
                      setState(() {
                        errorMessage = 'Please enter a MAC address';
                      });
                      return;
                    }
                    
                    // Basic MAC address format validation
                    final macRegex = RegExp(r'^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$');
                    if (!macRegex.hasMatch(macAddress)) {
                      setState(() {
                        errorMessage = 'Invalid MAC address format (use XX:XX:XX:XX:XX:XX)';
                      });
                      return;
                    }
                    
                    Navigator.of(context).pop();
                    _connectToDeviceByMac(macAddress);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: deepRed,
                    foregroundColor: Colors.white,
                  ),
                  child: Text('Connect Device'),
                ),
              ],
            );
          },
        );
      },
    );
  }

// New method to connect device by manually entered MAC address
Future<void> _connectToDeviceByMac(String macAddress) async {
  if (_selectedPet == null) return;

  try {
    final petId = _selectedPet!['id'];
    // Try updating existing mapping for this pet first
    final updateResp = await Supabase.instance.client
        .from('device_pet_map')
        .update({'device_id': macAddress})
        .eq('pet_id', petId)
        .select();

    if (updateResp == null || (updateResp is List && updateResp.isEmpty)) {
      // No existing mapping updated — insert a new mapping
      await Supabase.instance.client.from('device_pet_map').insert({
        'device_id': macAddress,
        'pet_id': petId,
      });
    }

    // fetch latest location after associating the device
    await _fetchLatestLocationForPet();

    debugPrint('Device MAC registered/updated! ID: $macAddress');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('GPS device connected successfully! MAC: $macAddress'),
        backgroundColor: Colors.green,
      ),
    );
  } catch (e) {
    debugPrint('Failed to register device MAC: $e');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Failed to connect device: $e'),
        backgroundColor: Colors.red,
      ),
    );
  }
}

// Helper method to fetch stored device ID from DB
Future<String?> _getStoredDeviceId() async {
  try {
    final response = await Supabase.instance.client
        .from('device_pet_map')
        .select('device_id')
        .eq('pet_id', _selectedPet!['id'])
        .limit(1);
    final data = response as List?;
    if (data != null && data.isNotEmpty) {
      return data.first['device_id']?.toString();
    }
  } catch (e) {}
  return null;
}

// Method to manually disconnect/remove the device
void _disconnectDevice() async {
  if (_selectedPet == null) return;
  
  // Show confirmation dialog
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          Icon(Icons.warning, color: Colors.orange),
          SizedBox(width: 8),
          Text('Disconnect GPS Device'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Are you sure you want to disconnect the GPS device?'),
          SizedBox(height: 8),
          Container(
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: Colors.orange, size: 16),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'This will stop location tracking for this pet.',
                    style: TextStyle(fontSize: 12, color: Colors.orange.shade700),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false), 
          child: Text('Cancel')
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text('Disconnect'),
        ),
      ],
    ),
  );

  if (confirm != true) return;

  try {
    // Remove device mapping from database
    await Supabase.instance.client
        .from('device_pet_map')
        .delete()
        .eq('pet_id', _selectedPet!['id']);
        
    // Clear local state
    setState(() {
      _latestDeviceId = null;
      _latestDeviceLocation = null;
      _latestDeviceTimestamp = null;
      _locationHistory = [];
      // Also clear current map view if it was showing device location
      if (_currentMapLocation == _latestDeviceLocation) {
        _currentMapLocation = null;
        _currentMapLabel = null;
        _currentMapSub = null;
      }
    });
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('GPS device disconnected successfully'),
        backgroundColor: Colors.green,
        action: SnackBarAction(
          label: 'Connect New',
          textColor: Colors.white,
          onPressed: () => _showBluetoothConnectionModal(context),
        ),
      ),
    );
  } catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Failed to disconnect: $e'),
        backgroundColor: Colors.red,
      ),
    );
  }
}

  // Helper to show confirmation and post lost pet to community
  Future<void> _showMissingConfirmationAndPost() async {
    if (_selectedPet == null) return;

    // Gather last known location and time
    double? lat;
    double? lng;
    String? address;
    DateTime? timestamp;

    // Prefer most recent from _locationHistory
    if (_locationHistory.isNotEmpty) {
      final latest = _locationHistory.first;
      lat = latest['latitude'];
      lng = latest['longitude'];
      address = latest['address']?.toString();
      timestamp = latest['timestamp'] as DateTime?;
    } else if (_latestDeviceLocation != null) {
      lat = _latestDeviceLocation!.latitude;
      lng = _latestDeviceLocation!.longitude;
      timestamp = _latestDeviceTimestamp;
    } else if (_selectedPet!['latitude'] != null && _selectedPet!['longitude'] != null) {
      lat = double.tryParse(_selectedPet!['latitude'].toString());
      lng = double.tryParse(_selectedPet!['longitude'].toString());
      // No timestamp available from pet fields
    }

  // Compose info for dialog
  final petName = _selectedPet!['name'] ?? 'Unnamed';
  final breed = _selectedPet!['breed'] ?? 'Unknown';
  final lastSeen = timestamp != null
      ? _formatTimestamp(timestamp)
      : _formatTimestamp(DateTime.now());
  String? resolvedAddress = address;
  // Always try to get the best address possible
  if ((resolvedAddress == null || resolvedAddress.isEmpty) && lat != null && lng != null) {
    resolvedAddress = await _reverseGeocode(lat, lng);
    // If reverse geocoding fails, we'll show coordinates as fallback
  }
  final locationStr = (resolvedAddress?.isNotEmpty ?? false)
      ? (lat != null && lng != null
          ? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)} - $resolvedAddress'
          : resolvedAddress)
      : (lat != null && lng != null
          ? 'Coordinates: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
          : 'No location available');
  final profilePicture = _selectedPet!['profile_picture'];

    // Check if current user is the owner or a sitter
    final userId = Supabase.instance.client.auth.currentUser?.id ?? '';
    final userRole = _getUserRole();
    final isOwner = userRole == 'Pet Owner' && _selectedPet!['owner_id'] == userId;
    
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Confirm Mark as Missing'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Pet: $petName', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Breed: $breed'),
            SizedBox(height: 8),
            Text('Last seen: $lastSeen'),
            Text('Location: $locationStr'),
            SizedBox(height: 12),
            Text(
              isOwner 
                ? 'This will mark your pet as missing and create a missing post in the community.'
                : 'This will mark the pet as missing and create an urgent missing post in the community. As a pet sitter, this will alert the owner and all community members.',
              style: TextStyle(
                color: isOwner ? Colors.grey[700] : Colors.orange[700],
                fontWeight: isOwner ? FontWeight.normal : FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: isOwner ? deepRed : Colors.orange),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Confirm'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        // Mark pet as missing
        await Supabase.instance.client
            .from('pets')
            .update({'is_missing': true})
            .eq('id', _selectedPet!['id']);
        setState(() {
          _selectedPet!['is_missing'] = true;
        });

        // Insert lost post into community_post
        final userId = Supabase.instance.client.auth.currentUser?.id ?? '';
        
        // Create different content based on user role (use previously determined isOwner)
        String content;
        if (isOwner) {
          content = 'My pet "$petName" (${breed}) was last seen at $locationStr on $lastSeen.';
        } else {
          // Pet sitter is reporting
          content = 'URGENT: Pet "$petName" (${breed}) went missing while under my care as a pet sitter. Last seen at $locationStr on $lastSeen. Please help find this pet and contact the owner immediately.';
        }
        
        final postResponse = await Supabase.instance.client
            .from('community_posts')
            .insert({
              'type': 'missing',
              'user_id': userId,
              'content': content,
              'latitude': lat,
              'longitude': lng,
              'address': resolvedAddress,
              'image_url': profilePicture,
              'created_at': timestamp?.toIso8601String() ?? DateTime.now().toIso8601String(),
            }).select('id');
            
         // Get the post ID from the response
         String? postId;
         if (postResponse is List && postResponse.isNotEmpty) {
           postId = postResponse.first['id']?.toString();
         }
         
         // Send pet alert notification to all users with post ID
         await sendPetAlertToAllUsers(
           petName: _selectedPet!['name'] ?? 'Unnamed',
           type: 'missing',
           actorId: userId,
           postId: postId,
         );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(isOwner 
                ? 'Pet marked as missing/lost and post created!'
                : 'Pet marked as missing! Urgent alert sent to community and owner.'),
              backgroundColor: isOwner ? null : Colors.orange,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to update: $e')),
          );
        }
      }
    }
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
          // Only show device hub for Pet Owners, not Pet Sitters (security measure)
          if (_getUserRole() == 'Pet Owner')
            IconButton(
              icon: Stack(
                children: [
                  Icon(Icons.device_hub),
                  if (_latestDeviceId != null)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1),
                        ),
                      ),
                    ),
                ],
              ),
              onPressed: () {
                _showBluetoothConnectionModal(context);
              },
              tooltip: _latestDeviceId != null 
                  ? 'GPS Device Connected (${_latestDeviceId})'
                  : 'Connect GPS Device',
            ),
          PopupMenuButton<Map<String, dynamic>>(
            icon: Icon(Icons.more_vert),
            onSelected: (pet) async {
              setState(() {
                _selectedPet = pet;
                // clear any previously pinned map/device state to avoid showing other pet's info
                _currentMapLocation = null;
                _currentMapLabel = null;
                _currentMapSub = null;
                _latestDeviceId = null;
                _latestDeviceLocation = null;
                _latestDeviceTimestamp = null;
                _locationHistory = [];
              });
              // update calendar markers right away
              await _fetchBehaviorDates();
              // fetch backend analysis (illness risk + numeric sleep forecast) immediately
              await _fetchAnalyzeFromBackend();
              await _fetchLatestAnalysis();
              await _fetchLatestLocationForPet(); // <-- ensure map refreshes for newly selected pet
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
                      _getUserRole() == 'Pet Sitter' 
                          ? 'No assigned pet yet' 
                          : 'No pet. Go to the profile to add a pet',
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
                                  // Update pet status
                                  await Supabase.instance.client
                                      .from('pets')
                                      .update({'is_missing': false})
                                      .eq('id', _selectedPet!['id']);
                                  setState(() {
                                    _selectedPet!['is_missing'] = false;
                                  });

                                  // Move lost post to found type in community_posts and update content
                                  final userId = Supabase.instance.client.auth.currentUser?.id ?? '';
                                  final petName = _selectedPet!['name'] ?? 'Unnamed';
                                  final breed = _selectedPet!['breed'] ?? 'Unknown';
                                  // Find the latest missing post for this pet and user
                                  final posts = await Supabase.instance.client
                                      .from('community_posts')
                                      .select()
                                      .eq('type', 'missing')
                                      .eq('user_id', userId)
                                      .ilike('content', '%$petName%');
                                  if (posts is List && posts.isNotEmpty) {
                                    final post = posts.first;
                                    final currentContent = post['content']?.toString() ?? '';
                                    final foundDate = DateFormat('MMM d, yyyy • hh:mm a').format(DateTime.now());
                                    final updatedContent = '$currentContent\n\nUPDATE: Pet is found at $foundDate';
                                    
                                    await Supabase.instance.client
                                        .from('community_posts')
                                        .update({
                                          'type': 'found',
                                          'content': updatedContent,
                                        })
                                        .eq('id', post['id']);
                                  }

                                  // Clear any active missing pet alerts for this pet
                                  MissingPetAlertService().clearLastMissingPost();

                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Pet marked as found! Lost post moved to found.')),
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
                              await _showMissingConfirmationAndPost();
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
    String? markerLabel;
    String? markerSub;

    // Use current map location if set, otherwise prefer latest device location
    if (_currentMapLocation != null) {
      lat = _currentMapLocation!.latitude;
      lng = _currentMapLocation!.longitude;
      markerLabel = _currentMapLabel;
      markerSub = _currentMapSub;
      markerWidget = CircleAvatar(
        radius: 20,
        backgroundColor: Colors.white,
        child: Icon(Icons.history, color: Colors.blue),
      );
    } else if (_latestDeviceLocation != null) {
      lat = _latestDeviceLocation!.latitude;
      lng = _latestDeviceLocation!.longitude;
      markerWidget = CircleAvatar(
        radius: 20,
        backgroundColor: Colors.white,
        child: Icon(Icons.gps_fixed, color: deepRed),
      );
      
      // Try to get address from location history or reverse geocode
      String? locationAddress;
      if (_locationHistory.isNotEmpty) {
        final latest = _locationHistory.first;
        locationAddress = latest['address']?.toString();
      }
      
      markerLabel = locationAddress?.isNotEmpty == true 
          ? '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)} - ${locationAddress!.length > 40 ? '${locationAddress.substring(0, 40)}...' : locationAddress}'
          : '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)} - ${_latestDeviceId ?? 'Device Location'}';
      markerSub = _latestDeviceTimestamp != null ? DateFormat('MMM d, HH:mm').format(_latestDeviceTimestamp!.toLocal()) : 'Last seen: unknown';
    } else if (_selectedPet != null &&
        _selectedPet!['latitude'] != null &&
        _selectedPet!['longitude'] != null) {
      // fallback to pet recorded location
      lat = double.tryParse(_selectedPet!['latitude'].toString());
      lng = double.tryParse(_selectedPet!['longitude'].toString());
      markerWidget = CircleAvatar(
        radius: 20,
        backgroundColor: Colors.white,
        child: Image.asset('assets/pets-profile-pictures.png', width: 32, height: 32, fit: BoxFit.cover),
      );
      markerLabel = _selectedPet!['name']?.toString() ?? 'Pet';
      markerSub = 'Saved location';
    }

    // Agusan del Norte coordinates
    final agusanDelNorteCenter = LatLng(9.0, 125.5);

    final mapCenter = (lat != null && lng != null)
        ? LatLng(lat, lng)
        : agusanDelNorteCenter;

        // Use a Column so we can show the map then location history below it
    return SingleChildScrollView(
      child: Column(
      children: [
        // Map area (fixed height)
        Container(
          height: 260,
          child: Stack(
      children: [
        FlutterMap(
          options: MapOptions(
            initialCenter: mapCenter,
            initialZoom: 11,
            // allow tapping the marker by tapping the map
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
                    point: LatLng(lat!, lng!),
                    width: 160,
                    height: 120,
                    child: GestureDetector(
                      onTap: () => _expandMapView(),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          markerWidget,
                          SizedBox(height: 4),
                          Flexible(
                            child: Container(
                              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    markerLabel ?? '', 
                                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (markerSub != null) 
                                    Text(
                                      markerSub, 
                                      style: TextStyle(fontSize: 9, color: Colors.grey[700]),
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
        // small floating button to refresh latest device location
        Positioned(
          right: 12,
          top: 12,
          child: Tooltip(
            message: 'Refresh location and addresses',
            child: FloatingActionButton(
              mini: true,
              backgroundColor: deepRed,
              child: Icon(Icons.refresh, size: 18, color: Colors.white),
              onPressed: () async {
                await _fetchLatestLocationForPet();
                // Force address refresh for items without addresses
                await _refreshAddressesForLocationHistory();
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Location and addresses refreshed')));
              },
            ),
          ),
        ),
            ],
          ),
        ),
        
        SizedBox(height: 12),
        // Location history section
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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Location History', style: TextStyle(fontWeight: FontWeight.bold)),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_currentMapLocation != null)
                        TextButton.icon(
                          icon: Icon(Icons.refresh, size: 16),
                          label: Text('Latest', style: TextStyle(fontSize: 12)),
                          onPressed: () {
                            setState(() {
                              _currentMapLocation = null;
                              _currentMapLabel = null;
                              _currentMapSub = null;
                            });
                          },
                        ),
                      TextButton.icon(
                        icon: Icon(Icons.fullscreen, size: 16),
                        label: Text('Expand Map', style: TextStyle(fontSize: 12)),
                        onPressed: () {
                          _expandMapView();
                        },
                      ),
                    ],
                  )
                ],
              ),
              SizedBox(height: 8),
              _locationHistory.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12.0),
                      child: Text('No recent locations', style: TextStyle(color: Colors.grey[700])),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      physics: NeverScrollableScrollPhysics(),
                      itemCount: _locationHistory.length,
                      separatorBuilder: (_, __) => Divider(height: 12),
                      itemBuilder: (context, idx) {
                        final r = _locationHistory[idx];
                        final address = (r['address'] as String?)?.toString();
                        final latv = r['latitude'];
                        final lngv = r['longitude'];
                        final ts = r['timestamp'] as DateTime?;
                        final device = r['device_mac']?.toString();
                        
                        // Prioritize address over coordinates, but show coordinates as fallback with "Coordinates:" prefix
                        String title;
                        Widget leadingIcon;
                        if (address != null && address.isNotEmpty) {
                          // Show coordinates + address when both are available
                          if (latv != null && lngv != null) {
                            title = '${latv.toStringAsFixed(5)}, ${lngv.toStringAsFixed(5)} - $address';
                          } else {
                            title = address;
                          }
                          leadingIcon = Icon(Icons.location_on, color: deepRed);
                        } else if (latv != null && lngv != null) {
                          title = 'Coordinates: ${latv.toStringAsFixed(5)}, ${lngv.toStringAsFixed(5)}';
                          leadingIcon = Icon(Icons.my_location, color: Colors.orange);
                        } else {
                          title = 'Unknown location';
                          leadingIcon = Icon(Icons.location_off, color: Colors.grey);
                        }
                        
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: leadingIcon,
                          title: Text(
                            title, 
                            style: TextStyle(fontSize: 14),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text('${_formatTimestamp(ts)}${device != null ? ' • $device' : ''}', style: TextStyle(fontSize: 12, color: Colors.grey[700])),
                          trailing: IconButton(
                            icon: Icon(Icons.visibility, color: deepRed),
                            tooltip: 'View on map',
                            onPressed: (latv != null && lngv != null) ? () {
                              final timestamp = _formatTimestamp(ts);
                              _updateMapView(LatLng(latv, lngv), title, timestamp);
                            } : null,
                          ),
                          onTap: (latv != null && lngv != null) ? () {
                            final timestamp = _formatTimestamp(ts);
                            _updateMapView(LatLng(latv, lngv), title, timestamp);
                          } : null,
                        );
                      },
                    ),
              ],
            ),
          ),
        ],
      ),
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
          // Fetch and display the actual pet owner's name
          FutureBuilder<String>(
            future: _getActualOwnerName(),
            builder: (context, snapshot) {
              final ownerName = snapshot.data ?? 'Loading...';
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Text(
                  'Owner: $ownerName\nPet: ${_selectedPet!['name'] ?? 'Unnamed'}\n\nScan opens: $publicUrl',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[800]),
                ),
              );
            },
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
    final bool isEdit = existing != null && existing['id'] != null;
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
                      Text("Activity Level", style: TextStyle(fontWeight: FontWeight.bold)),
                      SizedBox(height: 8),
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
                      Text("Sleep Hours", style: TextStyle(fontWeight: FontWeight.bold)),
                      SizedBox(height: 8),
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
                    ],
                  ),
                ),
              ),
                      SizedBox(height: 16),
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
                      );
                    },
                  );
      }
  }


// Full-screen map view widget
class _FullScreenMapView extends StatefulWidget {
  final LatLng center;
  final LatLng? markerLocation;
  final String? markerLabel;
  final String? markerSub;
  final List<Map<String, dynamic>> locationHistory;
  final Function(LatLng, String, String) onLocationSelected;

  const _FullScreenMapView({
    required this.center,
    this.markerLocation,
    this.markerLabel,
    this.markerSub,
    required this.locationHistory,
    required this.onLocationSelected,
  });

  @override
  _FullScreenMapViewState createState() => _FullScreenMapViewState();
}

class _FullScreenMapViewState extends State<_FullScreenMapView> {
  late LatLng _currentCenter;
  late String? _currentLabel;
  late String? _currentSub;
  bool _showLocationHistory = false;

  @override
  void initState() {
    super.initState();
    _currentCenter = widget.markerLocation ?? widget.center;
    _currentLabel = widget.markerLabel;
    _currentSub = widget.markerSub;
  }

  void _updateMapLocation(LatLng location, String label, String subtitle) {
    setState(() {
      _currentCenter = location;
      _currentLabel = label;
      _currentSub = subtitle;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: lightBlush,
      appBar: AppBar(
        backgroundColor: const Color(0xFFCB4154),
        elevation: 0,
        title: Text('Pet Location Map', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: Icon(Icons.history),
            onPressed: () {
              setState(() {
                _showLocationHistory = !_showLocationHistory;
              });
            },
          ),
          IconButton(
            icon: Icon(Icons.check),
            onPressed: () {
              if (_currentLabel != null && _currentSub != null) {
                widget.onLocationSelected(_currentCenter, _currentLabel!, _currentSub!);
              } else {
                Navigator.pop(context);
              }
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            options: MapOptions(
              initialCenter: _currentCenter,
              initialZoom: 14,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                subdomains: const ['a', 'b', 'c'],
              ),
              MarkerLayer(
                markers: [
                  if (widget.markerLocation != null)
                    Marker(
                      point: _currentCenter,
                      width: 200,
                      height: 150,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                            radius: 25,
                            backgroundColor: Colors.white,
                            child: Icon(Icons.location_on, color: deepRed, size: 30),
                          ),
                          SizedBox(height: 8),
                          Container(
                            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_currentLabel != null)
                                  Text(
                                    _currentLabel!,
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                    textAlign: TextAlign.center,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                if (_currentSub != null)
                                  Text(
                                    _currentSub!,
                                    style: TextStyle(fontSize: 10, color: Colors.grey[700]),
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
          if (_showLocationHistory)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Container(
                height: 250,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 8)],
                ),
                child: Column(
                  children: [
                    Container(
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: deepRed,
                        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                      ),
                      child: Row(
                        children: [
                          Text('Location History', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          Spacer(),
                          IconButton(
                            icon: Icon(Icons.close, color: Colors.white),
                            onPressed: () {
                              setState(() {
                                _showLocationHistory = false;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: widget.locationHistory.isEmpty
                          ? Center(
                              child: Text('No recent locations', style: TextStyle(color: Colors.grey[700])),
                            )
                          : ListView.separated(
                              padding: EdgeInsets.all(8),
                              itemCount: widget.locationHistory.length,
                              separatorBuilder: (_, __) => Divider(height: 8),
                              itemBuilder: (context, idx) {
                                final r = widget.locationHistory[idx];
                                final address = (r['address'] as String?)?.toString();
                                final latv = r['latitude'];
                                final lngv = r['longitude'];
                                final ts = r['timestamp'] as DateTime?;
                                
                                String title;
                                if (address != null && address.isNotEmpty) {
                                  if (latv != null && lngv != null) {
                                    title = '${latv.toStringAsFixed(5)}, ${lngv.toStringAsFixed(5)} - $address';
                                  } else {
                                    title = address;
                                  }
                                } else if (latv != null && lngv != null) {
                                  title = 'Coordinates: ${latv.toStringAsFixed(5)}, ${lngv.toStringAsFixed(5)}';
                                } else {
                                  title = 'Unknown location';
                                }
                                
                                final timestamp = ts != null 
                                    ? DateFormat('MMM d, yyyy • hh:mm a').format(ts.toLocal())
                                    : '-';
                                
                                return ListTile(
                                  dense: true,
                                  leading: Icon(Icons.location_on, color: deepRed, size: 20),
                                  title: Text(
                                    title,
                                    style: TextStyle(fontSize: 12),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(timestamp, style: TextStyle(fontSize: 10)),
                                  onTap: (latv != null && lngv != null) ? () {
                                    _updateMapLocation(LatLng(latv, lngv), title, timestamp);
                                  } : null,
                                );
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
  }
}
