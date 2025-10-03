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
import '../services/location_sync_service.dart';

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
  // debug prints removed
    return role;
  }

  // Helper method to get formatted age for pet display
  String _getFormattedAge(Map<String, dynamic> pet) {
    if (pet['date_of_birth'] != null) {
      try {
        final birthDate = DateTime.parse(pet['date_of_birth'].toString());
        return _formatAgeFromBirthDate(birthDate);
      } catch (e) {
        // Fallback to old age format
        final age = pet['age'] ?? 0;
        return '$age ${age == 1 ? 'year' : 'years'} old';
      }
    } else {
      // Fallback to old age format
      final age = pet['age'] ?? 0;
      return '$age ${age == 1 ? 'year' : 'years'} old';
    }
  }

  // Helper method to format age from birth date
  String _formatAgeFromBirthDate(DateTime birthDate) {
    final now = DateTime.now();
    int years = now.year - birthDate.year;
    int months = now.month - birthDate.month;
    int days = now.day - birthDate.day;

    if (days < 0) {
      months--;
      days += DateTime(now.year, now.month, 0).day;
    }
    if (months < 0) {
      years--;
      months += 12;
    }

    if (years > 0) {
      if (months > 0) {
        return '$years ${years == 1 ? 'year' : 'years'}, $months ${months == 1 ? 'month' : 'months'} old';
      } else {
        return '$years ${years == 1 ? 'year' : 'years'} old';
      }
    } else if (months > 0) {
      if (days > 0) {
        return '$months ${months == 1 ? 'month' : 'months'}, $days ${days == 1 ? 'day' : 'days'} old';
      } else {
        return '$months ${months == 1 ? 'month' : 'months'} old';
      }
    } else {
      return '$days ${days == 1 ? 'day' : 'days'} old';
    }
  }

  List<Map<String, dynamic>> _pets = [];
  Map<String, dynamic>? _selectedPet;
  
  // Caching mechanism for pet data
  final Map<String, Map<String, dynamic>> _petDataCache = {};
  final Map<String, DateTime> _petDataCacheTimestamp = {};
  final Duration _cacheValidDuration = Duration(minutes: 5);
  
  // Loading states for better UX
  bool _loadingBehaviorData = false;
  bool _loadingAnalysisData = false;
  bool _loadingLocationData = false;

  // loading flag to know when we've finished fetching pets
  bool _loadingPets = true;

  String backendUrl = "https://pettrackcare.onrender.com/analyze";
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

  // Latest mood from behavior logs for display in health status
  String? _latestMood;

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

  // Enhanced missing pet modal state
  final TextEditingController _emergencyContactController = TextEditingController();
  final TextEditingController _rewardAmountController = TextEditingController();
  final TextEditingController _customMessageController = TextEditingController();
  final TextEditingController _specialNotesController = TextEditingController();
  String _urgencyLevel = 'High';
  bool _hasReward = false;
  bool _hasMicrochip = false;
  String _microchipNumber = '';

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
    'High': '🐕',
    'Medium': '🐾',
    'Low': '🐶',
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

  // Helper method to check if cached data is still valid
  bool _isCacheValid(String petId) {
    final timestamp = _petDataCacheTimestamp[petId];
    if (timestamp == null) return false;
    return DateTime.now().difference(timestamp) < _cacheValidDuration;
  }

  // Helper method to cache pet data
  void _cachePetData(String petId, Map<String, dynamic> data) {
    _petDataCache[petId] = data;
    _petDataCacheTimestamp[petId] = DateTime.now();
  }

  // Helper method to get cached pet data
  Map<String, dynamic>? _getCachedPetData(String petId) {
    if (_isCacheValid(petId)) {
      return _petDataCache[petId];
    }
    return null;
  }

  // Background data fetching with caching
  Future<void> _fetchPetDataInBackground(String petId) async {
    try {
      // Fetch all data in parallel for better performance
      final results = await Future.wait([
        _fetchBehaviorDates(),
        _fetchAnalyzeFromBackend(),
        _fetchLatestAnalysis(),
        _fetchLatestLocationForPet(),
      ]);

      // Cache the results
      final dataToCache = {
        'events': _events,
        'prediction': _prediction,
        'recommendation': _recommendation,
        'sleepTrend': _sleepTrend,
        'moodProb': _moodProb,
        'activityProb': _activityProb,
        'illnessRisk': _illnessRisk,
        'isUnhealthy': _isUnhealthy,
        'careActions': _careActions,
        'careExpectations': _careExpectations,
      };
      _cachePetData(petId, dataToCache);

      // Update loading states
      if (mounted) {
        setState(() {
          _loadingBehaviorData = false;
          _loadingAnalysisData = false;
          _loadingLocationData = false;
        });
      }
    } catch (e) {
      // Handle errors gracefully
      if (mounted) {
        setState(() {
          _loadingBehaviorData = false;
          _loadingAnalysisData = false;
          _loadingLocationData = false;
        });
      }
    }
  }

  Future<void> _fetchPets() async {
    final userId = user?.id;
    if (userId == null) {
      setState(() => _loadingPets = false);
      return;
    }

  setState(() => _loadingPets = true);
    try {
      List<Map<String, dynamic>> list = [];
      
      if (_getUserRole() == 'Pet Sitter') {
        // First, get the sitting_jobs with status 'Active' for this sitter
        final sittingJobsResponse = await Supabase.instance.client
            .from('sitting_jobs')
            .select('pet_id, status')
            .eq('sitter_id', userId)
            .eq('status', 'Active');
            
        final sittingJobsData = sittingJobsResponse as List?;
        
        if (sittingJobsData != null && sittingJobsData.isNotEmpty) {
          final petIds = sittingJobsData
              .map((job) => job['pet_id'])
              .where((id) => id != null)
              .toList();

          if (petIds.isNotEmpty) {
            // Now fetch the actual pets using these IDs
            final petsResponse = await Supabase.instance.client
                .from('pets')
                .select()
                .inFilter('id', petIds)
                .order('id', ascending: false);
                
            final petsData = petsResponse as List?;
            if (petsData != null && petsData.isNotEmpty) {
              list = List<Map<String, dynamic>>.from(petsData);
            } 
          } 
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

    // Fetch latest mood from behavior logs
    await _fetchLatestMood();

    // also refresh calendar markers
    await _fetchBehaviorDates();
  }

  // Fetch the latest mood from behavior logs
  Future<void> _fetchLatestMood() async {
    if (_selectedPet == null) return;
    try {
      final petId = _selectedPet!['id'];
      final response = await Supabase.instance.client
          .from('behavior_logs')
          .select('mood')
          .eq('pet_id', petId)
          .not('mood', 'is', null)
          .order('log_date', ascending: false)
          .limit(1);

      final data = response as List?;
      if (data != null && data.isNotEmpty) {
        final latestLog = data.first as Map<String, dynamic>;
        setState(() {
          _latestMood = latestLog['mood']?.toString();
        });
      } else {
        setState(() {
          _latestMood = null;
        });
      }
    } catch (e) {
      // Error fetching latest mood
      setState(() {
        _latestMood = null;
      });
    }
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
      // Error fetching owner name
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
    _emergencyContactController.dispose();
    _rewardAmountController.dispose();
    _customMessageController.dispose();
    _specialNotesController.dispose();
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

  // debugPrint removed
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('GPS device connected successfully! MAC: $macAddress'),
        backgroundColor: Colors.green,
      ),
    );
  } catch (e) {
  // debugPrint removed
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

  // Helper to show enhanced missing confirmation modal
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
            : resolvedAddress!)
        : (lat != null && lng != null
            ? 'Coordinates: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
            : 'No location available');
    final profilePicture = _selectedPet!['profile_picture'];

    // Check if current user is the owner or a sitter
    final userId = Supabase.instance.client.auth.currentUser?.id ?? '';
    final userRole = _getUserRole();
    final isOwner = userRole == 'Pet Owner' && _selectedPet!['owner_id'] == userId;
    
    // Reset form controllers
    _emergencyContactController.clear();
    _rewardAmountController.clear();
    _customMessageController.clear();
    _specialNotesController.clear();
    _hasReward = false;
    _hasMicrochip = false;
    _microchipNumber = '';
    _urgencyLevel = 'High';

    // Show enhanced modal
    final confirmed = await _showEnhancedMissingModal(
      petName: petName,
      breed: breed,
      lastSeen: lastSeen,
      locationStr: locationStr,
      profilePicture: profilePicture,
      isOwner: isOwner,
      lat: lat,
      lng: lng,
    );

    if (confirmed == true) {
      try {
        // Mark pet as missing
        await Supabase.instance.client
            .from('pets')
            .update({'is_missing': true})
            .eq('id', _selectedPet!['id']);
        setState(() {
          _selectedPet!['is_missing'] = true;
        });

        // Create enhanced content for community post
        String content = _buildMissingPostContent(
          petName: petName,
          breed: breed,
          locationStr: locationStr,
          lastSeen: lastSeen,
          isOwner: isOwner,
        );
        
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
         if (postResponse.isNotEmpty) {
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
                ? 'Pet marked as missing/lost and community alert created!'
                : 'Pet marked as missing! Urgent alert sent to community and owner.'),
              backgroundColor: isOwner ? deepRed : Colors.orange,
              duration: Duration(seconds: 4),
              action: SnackBarAction(
                label: 'View',
                textColor: Colors.white,
                onPressed: () {
                  // Navigate to community screen to view the post
                },
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to create missing alert: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  // Enhanced missing modal with detailed information and options
  Future<bool?> _showEnhancedMissingModal({
    required String petName,
    required String breed,
    required String lastSeen,
    required String locationStr,
    String? profilePicture,
    required bool isOwner,
    double? lat,
    double? lng,
  }) async {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header with pet photo and urgent banner
                _buildMissingModalHeader(petName, profilePicture, isOwner),
                
                Flexible(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Pet basic info section
                        _buildPetBasicInfoSection(petName, breed, lastSeen, locationStr, lat, lng),
                        
                        SizedBox(height: 20),
                        
                        // Emergency contact section
                        _buildEmergencyContactSection(setModalState),
                        
                        SizedBox(height: 20),
                        
                        // Additional details section
                        _buildAdditionalDetailsSection(setModalState),
                        
                        SizedBox(height: 20),
                        
                        // Custom message section
                        _buildCustomMessageSection(setModalState),
                        
                        SizedBox(height: 20),
                        
                        // Urgency and sharing options
                        _buildUrgencyAndSharingSection(setModalState),
                      ],
                    ),
                  ),
                ),
                
                // Action buttons
                _buildMissingModalActions(context, isOwner),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Build enhanced missing post content with all details
  String _buildMissingPostContent({
    required String petName,
    required String breed,
    required String locationStr,
    required String lastSeen,
    required bool isOwner,
  }) {
    String content = '';
    
    // Urgency header
    switch (_urgencyLevel) {
      case 'Critical':
        content += '🚨 CRITICAL MISSING PET ALERT 🚨\n\n';
        break;
      case 'High':
        content += '⚠️ URGENT: MISSING PET ⚠️\n\n';
        break;
      case 'Medium':
        content += '🔍 Missing Pet Alert\n\n';
        break;
    }
    
    // Basic info
    if (isOwner) {
      content += 'My beloved pet "$petName" ($breed) is missing!\n\n';
    } else {
      content += 'URGENT: Pet "$petName" ($breed) went missing while under my care as a pet sitter.\n\n';
    }
    
    // Location and time
    content += '📍 Last seen: $locationStr\n';
    content += '⏰ Time: $lastSeen\n\n';
    
    // Custom message if provided
    if (_customMessageController.text.isNotEmpty) {
      content += '📝 Additional Details:\n${_customMessageController.text}\n\n';
    }
    
    // Special notes if provided
    if (_specialNotesController.text.isNotEmpty) {
      content += '⚠️ Important Notes:\n${_specialNotesController.text}\n\n';
    }
    
    // Microchip info
    if (_hasMicrochip && _microchipNumber.isNotEmpty) {
      content += '🔍 Microchip ID: $_microchipNumber\n\n';
    }
    
    // Reward info
    if (_hasReward && _rewardAmountController.text.isNotEmpty) {
      content += '💰 Reward Offered: ₱ ${_rewardAmountController.text}\n\n';
    }
    
    // Contact info
    if (_emergencyContactController.text.isNotEmpty) {
      content += '📞 Emergency Contact: ${_emergencyContactController.text}\n\n';
    }
    
    return content;
  }

  // Build modal header with pet photo and urgent banner
  Widget _buildMissingModalHeader(String petName, String? profilePicture, bool isOwner) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isOwner 
            ? [deepRed, coral]
            : [Colors.orange, Colors.deepOrange],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Row(
          children: [
            // Pet photo
            Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                color: Colors.white,
              ),
              child: ClipOval(
                child: profilePicture != null && profilePicture.isNotEmpty
                  ? Image.network(
                      profilePicture,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => 
                        Icon(Icons.pets, size: 35, color: deepRed),
                    )
                  : Icon(Icons.pets, size: 35, color: deepRed),
              ),
            ),
            
            SizedBox(width: 15),
            
            // Title and urgency indicator
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.warning, color: Colors.white, size: 24),
                      SizedBox(width: 8),
                      Text(
                        'MISSING PET ALERT',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 5),
                  Text(
                    petName,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                  SizedBox(height: 5),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      isOwner ? 'Owner Report' : 'Pet Sitter Alert',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
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

  // Build pet basic info section
  Widget _buildPetBasicInfoSection(String petName, String breed, String lastSeen, String locationStr, double? lat, double? lng) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pets, color: deepRed, size: 20),
              SizedBox(width: 8),
              Text(
                'Pet Information',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: deepRed,
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          
          _buildInfoRow(Icons.label, 'Name', petName),
          _buildInfoRow(Icons.category, 'Breed', breed),
          _buildInfoRow(Icons.access_time, 'Last Seen', lastSeen),
          _buildInfoRow(Icons.location_on, 'Location', locationStr),
          
          if (lat != null && lng != null) ...[
            SizedBox(height: 8),
            Container(
              height: 120,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  children: [
                    // Placeholder for map - in a real app you'd use a proper map widget
                    Container(
                      color: Colors.blue.shade50,
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.map, size: 40, color: Colors.blue.shade400),
                            SizedBox(height: 8),
                            Text(
                              'Last Known Location',
                              style: TextStyle(color: Colors.blue.shade600, fontWeight: FontWeight.w500),
                            ),
                            Text(
                              '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                              style: TextStyle(color: Colors.blue.shade600, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                    
                    // Expand map button
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 4,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        child: IconButton(
                          icon: Icon(Icons.fullscreen, size: 18),
                          onPressed: () {
                            // Expand map functionality
                            if (lat != null && lng != null) {
                              _expandMapView();
                            }
                          },
                          constraints: BoxConstraints(minWidth: 30, minHeight: 30),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Build emergency contact section
  Widget _buildEmergencyContactSection(StateSetter setModalState) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.contact_phone, color: Colors.red.shade700, size: 20),
              SizedBox(width: 8),
              Text(
                'Emergency Contact Information',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.red.shade700,
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Text(
            'Provide a contact number for anyone who finds your pet',
            style: TextStyle(color: Colors.red.shade600, fontSize: 12),
          ),
          SizedBox(height: 12),
          
          TextField(
            controller: _emergencyContactController,
            decoration: InputDecoration(
              labelText: 'Phone Number',
              hintText: 'e.g., +1 (555) 123-4567',
              prefixIcon: Icon(Icons.phone, color: Colors.red.shade600),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.red.shade300),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.red.shade600, width: 2),
              ),
              filled: true,
              fillColor: Colors.white,
            ),
            keyboardType: TextInputType.phone,
            onChanged: (value) => setModalState(() {}),
          ),
        ],
      ),
    );
  }

  // Build additional details section
  Widget _buildAdditionalDetailsSection(StateSetter setModalState) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: Colors.blue.shade700, size: 20),
              SizedBox(width: 8),
              Text(
                'Additional Details',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue.shade700,
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
          
          // Microchip toggle
          Row(
            children: [
              Checkbox(
                value: _hasMicrochip,
                onChanged: (value) {
                  setModalState(() {
                    _hasMicrochip = value ?? false;
                    if (!_hasMicrochip) _microchipNumber = '';
                  });
                },
                activeColor: Colors.blue.shade600,
              ),
              Expanded(
                child: Text(
                  'Pet has microchip',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          
          // Microchip number field
          if (_hasMicrochip) ...[
            SizedBox(height: 8),
            TextField(
              decoration: InputDecoration(
                labelText: 'Microchip Number',
                hintText: 'Enter microchip ID',
                prefixIcon: Icon(Icons.memory, color: Colors.blue.shade600),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                filled: true,
                fillColor: Colors.white,
              ),
              onChanged: (value) {
                setModalState(() {
                  _microchipNumber = value;
                });
              },
            ),
          ],
          
          SizedBox(height: 16),
          
          // Reward toggle
          Row(
            children: [
              Checkbox(
                value: _hasReward,
                onChanged: (value) {
                  setModalState(() {
                    _hasReward = value ?? false;
                    if (!_hasReward) _rewardAmountController.clear();
                  });
                },
                activeColor: Colors.green.shade600,
              ),
              Expanded(
                child: Text(
                  'Offering reward for safe return',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          
          // Reward amount field
          if (_hasReward) ...[
            SizedBox(height: 8),
            TextField(
              controller: _rewardAmountController,
              decoration: InputDecoration(
                labelText: 'Reward Amount',
                hintText: 'e.g., 500',
                prefixIcon: Icon(Icons.monetization_on, color: Colors.green.shade600),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                filled: true,
                fillColor: Colors.white,
              ),
              keyboardType: TextInputType.number,
              onChanged: (value) => setModalState(() {}),
            ),
          ],
          
          SizedBox(height: 16),
          
          // Special notes
          TextField(
            controller: _specialNotesController,
            decoration: InputDecoration(
              labelText: 'Special Notes',
              hintText: 'Medical conditions, temperament, special instructions...',
              prefixIcon: Icon(Icons.note, color: Colors.blue.shade600),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              filled: true,
              fillColor: Colors.white,
            ),
            maxLines: 3,
            onChanged: (value) => setModalState(() {}),
          ),
        ],
      ),
    );
  }

  // Build custom message section
  Widget _buildCustomMessageSection(StateSetter setModalState) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.message, color: Colors.orange.shade700, size: 20),
              SizedBox(width: 8),
              Text(
                'Custom Message to Community',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.orange.shade700,
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Text(
            'Describe the circumstances or add personal appeal',
            style: TextStyle(color: Colors.orange.shade600, fontSize: 12),
          ),
          SizedBox(height: 12),
          
          TextField(
            controller: _customMessageController,
            decoration: InputDecoration(
              labelText: 'Your Message',
              hintText: 'Please help us find our beloved pet. Any information would be greatly appreciated...',
              prefixIcon: Icon(Icons.edit, color: Colors.orange.shade600),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              filled: true,
              fillColor: Colors.white,
            ),
            maxLines: 4,
            maxLength: 500,
            onChanged: (value) => setModalState(() {}),
          ),
        ],
      ),
    );
  }

  // Build urgency and sharing section
  Widget _buildUrgencyAndSharingSection(StateSetter setModalState) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.purple.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.purple.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.priority_high, color: Colors.purple.shade700, size: 20),
              SizedBox(width: 8),
              Text(
                'Alert Settings',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.purple.shade700,
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
          
          // Urgency level
          Text(
            'Urgency Level',
            style: TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
          ),
          SizedBox(height: 8),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.purple.shade300),
              borderRadius: BorderRadius.circular(8),
              color: Colors.white,
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _urgencyLevel,
                isExpanded: true,
                items: [
                  DropdownMenuItem(
                    value: 'Critical',
                    child: Row(
                      children: [
                        Icon(Icons.emergency, color: Colors.red, size: 18),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '🚨 Critical - Immediate danger',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'High',
                    child: Row(
                      children: [
                        Icon(Icons.warning, color: Colors.orange, size: 18),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '⚠️ High - Just went missing',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'Medium',
                    child: Row(
                      children: [
                        Icon(Icons.info, color: Colors.blue, size: 18),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '🔍 Medium - Missing for a while',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                onChanged: (value) {
                  setModalState(() {
                    _urgencyLevel = value ?? 'High';
                  });
                },
              ),
            ),
          ),
          
          SizedBox(height: 16),
          
          // Quick action buttons
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: Icon(Icons.copy, size: 16),
                  label: Text(
                    'Copy Details',
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.purple.shade100,
                    foregroundColor: Colors.purple.shade700,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                  ),
                  onPressed: () {
                    _copyPetDetailsToClipboard();
                  },
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  icon: Icon(Icons.share, size: 16),
                  label: Text(
                    'Share Info',
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.purple.shade100,
                    foregroundColor: Colors.purple.shade700,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                  ),
                  onPressed: () {
                    _sharePetInfo();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Build modal action buttons
  Widget _buildMissingModalActions(BuildContext context, bool isOwner) {
    return Container(
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(20),
        ),
      ),
      child: Column(
        children: [
          // Warning text
          Container(
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.amber.shade300),
            ),
            child: Row(
              children: [
                Icon(Icons.info, color: Colors.amber.shade700, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isOwner 
                      ? 'This will create a community alert and notify all nearby users.'
                      : 'This will immediately alert the owner and all community members.',
                    style: TextStyle(
                      color: Colors.amber.shade700,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          SizedBox(height: 16),
          
          // Action buttons
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(
                    'Cancel',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isOwner ? deepRed : Colors.orange,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: 2,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.campaign, size: 18),
                      SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Create Missing Alert',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
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
    );
  }

  // Helper widget for info rows
  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: Colors.grey.shade600),
          SizedBox(width: 8),
          SizedBox(
            width: 70,
            child: Text(
              '$label:',
              style: TextStyle(
                fontWeight: FontWeight.w500,
                color: Colors.grey.shade700,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }

  // Copy pet details to clipboard
  void _copyPetDetailsToClipboard() {
    if (_selectedPet == null) return;
    
    final petName = _selectedPet!['name'] ?? 'Unnamed';
    final breed = _selectedPet!['breed'] ?? 'Unknown';
    
    String details = 'MISSING PET ALERT\n\n';
    details += 'Name: $petName\n';
    details += 'Breed: $breed\n';
    
    if (_emergencyContactController.text.isNotEmpty) {
      details += 'Contact: ${_emergencyContactController.text}\n';
    }
    
    if (_hasMicrochip && _microchipNumber.isNotEmpty) {
      details += 'Microchip: $_microchipNumber\n';
    }
    
    if (_hasReward && _rewardAmountController.text.isNotEmpty) {
      details += 'Reward: ₱${_rewardAmountController.text}\n';
    }
    
    if (_customMessageController.text.isNotEmpty) {
      details += '\nMessage: ${_customMessageController.text}\n';
    }
    
    if (_specialNotesController.text.isNotEmpty) {
      details += '\nSpecial Notes: ${_specialNotesController.text}\n';
    }
    
    details += '\nPlease help bring $petName home safely!';
    
    Clipboard.setData(ClipboardData(text: details));
    HapticFeedback.lightImpact();
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Pet details copied to clipboard'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
      ),
    );
  }

  // Share pet information
  void _sharePetInfo() {
    // In a real app, this would use the share package
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Sharing functionality would be implemented here'),
        backgroundColor: Colors.blue,
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: lightBlush,
      appBar: AppBar(
        backgroundColor: deepRed,
        elevation: 0,
        title: Row(
          children: [
            SizedBox(width: 12),
            Text(
              'Pet Profile',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
                fontSize: 20,
              ),
            ),
          ],
        ),
        actions: [
          Container(
            margin: EdgeInsets.only(right: 4),
            child: IconButton(
              icon: Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.notifications_outlined,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const NotificationScreen(),
                  ),
                );
              },
              tooltip: 'Notifications',
            ),
          ),
          // Only show device hub for Pet Owners, not Pet Sitters (security measure)
          if (_getUserRole() == 'Pet Owner')
            Container(
              margin: EdgeInsets.only(right: 4),
              child: IconButton(
                icon: Container(
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Stack(
                    children: [
                      Icon(
                        Icons.device_hub,
                        color: Colors.white,
                        size: 20,
                      ),
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
                ),
                onPressed: () {
                  _showBluetoothConnectionModal(context);
                },
                tooltip: _latestDeviceId != null 
                    ? 'GPS Device Connected (${_latestDeviceId})'
                    : 'Connect GPS Device',
              ),
            ),
          Container(
            margin: EdgeInsets.only(right: 8),
            child: PopupMenuButton<Map<String, dynamic>>(
              icon: Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Show selected pet's avatar
                    if (_selectedPet != null) ...[
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1),
                        ),
                        child: ClipOval(
                          child: _selectedPet!['profile_picture'] != null && _selectedPet!['profile_picture'].isNotEmpty
                              ? Image.network(
                                  _selectedPet!['profile_picture'],
                                  fit: BoxFit.cover,
                                  width: 24,
                                  height: 24,
                                  errorBuilder: (context, error, stackTrace) {
                                    return Container(
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        gradient: LinearGradient(
                                          colors: [coral.withOpacity(0.8), peach.withOpacity(0.8)],
                                        ),
                                      ),
                                      child: Center(
                                        child: Text(
                                          (_selectedPet!['name'] ?? 'U')[0].toUpperCase(),
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                )
                              : Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      colors: [coral.withOpacity(0.8), peach.withOpacity(0.8)],
                                    ),
                                  ),
                                  child: Center(
                                    child: Text(
                                      (_selectedPet!['name'] ?? 'U')[0].toUpperCase(),
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      SizedBox(width: 8),
                      // Show selected pet's name
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: 100),
                        child: Text(
                          _selectedPet!['name'] ?? 'Unnamed',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      SizedBox(width: 4),
                    ],
                    Icon(
                      Icons.keyboard_arrow_down,
                      color: Colors.white,
                      size: 18,
                    ),
                  ],
                ),
              ),
              tooltip: _selectedPet != null ? 'Switch Pet (${_selectedPet!['name']})' : 'Select Pet',
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              color: Colors.white,
              elevation: 8,
              onSelected: (pet) async {
                final petId = pet['id']?.toString();
                if (petId == null) return;
                
                // Quick UI update first for immediate response
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
                  // Set loading states
                  _loadingBehaviorData = true;
                  _loadingAnalysisData = true;
                  _loadingLocationData = true;
                });
                
                // Check if we have cached data
                final cachedData = _getCachedPetData(petId);
                if (cachedData != null) {
                  // Use cached data for immediate display
                  setState(() {
                    _events = cachedData['events'] ?? {};
                    _prediction = cachedData['prediction'];
                    _recommendation = cachedData['recommendation'];
                    _sleepTrend = cachedData['sleepTrend'] ?? [];
                    _moodProb = cachedData['moodProb'] ?? {};
                    _activityProb = cachedData['activityProb'] ?? {};
                    _illnessRisk = cachedData['illnessRisk'];
                    _isUnhealthy = cachedData['isUnhealthy'] ?? false;
                    _careActions = cachedData['careActions'] ?? [];
                    _careExpectations = cachedData['careExpectations'] ?? [];
                    _loadingBehaviorData = false;
                    _loadingAnalysisData = false;
                  });
                }
                
                // Fetch fresh data in background
                _fetchPetDataInBackground(petId);
              },
              itemBuilder: (context) {
                List<PopupMenuEntry<Map<String, dynamic>>> items = [];
                
                // Add header
                items.add(
                  PopupMenuItem(
                    enabled: false,
                    child: Container(
                      padding: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.pets, color: coral, size: 20),
                              SizedBox(width: 8),
                              Text(
                                'Choose Pet Profile',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: deepRed,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Select which pet profile to view and manage',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                          SizedBox(height: 8),
                          Divider(height: 1, color: Colors.grey.shade300),
                        ],
                      ),
                    ),
                  ),
                );
                
                // Add pet items
                items.addAll(_pets.map((pet) {
                  final isSelected = pet == _selectedPet;
                  return PopupMenuItem(
                    value: pet,
                    child: Container(
                      margin: EdgeInsets.symmetric(vertical: 4),
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isSelected ? lightBlush : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected ? coral : Colors.grey.shade300,
                          width: isSelected ? 2 : 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.05),
                            blurRadius: 4,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          // Enhanced pet profile picture or avatar
                          Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isSelected ? coral : Colors.grey.shade300,
                                width: 2,
                              ),
                            ),
                            child: ClipOval(
                              child: pet['profile_picture'] != null && pet['profile_picture'].isNotEmpty
                                  ? Image.network(
                                      pet['profile_picture'],
                                      fit: BoxFit.cover,
                                      width: 50,
                                      height: 50,
                                      errorBuilder: (context, error, stackTrace) {
                                        return _buildPetAvatar(pet, isSelected);
                                      },
                                    )
                                  : _buildPetAvatar(pet, isSelected),
                            ),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Pet name
                                Text(
                                  pet['name'] ?? 'Unnamed',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: isSelected ? deepRed : Colors.grey.shade800,
                                    fontSize: 16,
                                  ),
                                ),
                                SizedBox(height: 4),
                                // Pet details row
                                Row(
                                  children: [
                                    // Breed and age
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          if (pet['breed'] != null)
                                            Text(
                                              pet['breed'],
                                              style: TextStyle(
                                                fontSize: 13,
                                                color: coral,
                                                fontWeight: FontWeight.w500,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          if (pet['age'] != null)
                                            Text(
                                              _getFormattedAge(pet),
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey.shade600,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    // Health status indicator
                                    Container(
                                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: _getHealthStatusColor(pet['health'] ?? 'Good').withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        pet['health'] ?? 'Good',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: _getHealthStatusColor(pet['health'] ?? 'Good'),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                // Pet type and gender
                                SizedBox(height: 2),
                                Row(
                                  children: [
                                    Icon(
                                      _getPetTypeIcon(pet['type'] ?? 'Dog'),
                                      size: 14,
                                      color: Colors.grey.shade600,
                                    ),
                                    SizedBox(width: 4),
                                    Text(
                                      '${pet['type'] ?? 'Dog'} • ${pet['gender'] ?? 'Unknown'}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                    if (pet['weight'] != null) ...[
                                      Text(
                                        ' • ${pet['weight']}kg',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                          // Selection indicator
                          if (isSelected)
                            Container(
                              padding: EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: coral,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.check,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                }).toList());
                
                return items;
              },
            ),
          ),
        ],
      ),
      body: _loadingPets
          ? Center(child: CircularProgressIndicator(color: deepRed))
          : _pets.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.pets, size: 64, color: deepRed.withOpacity(0.5)),
                        SizedBox(height: 16),
                        Text(
                          _getUserRole() == 'Pet Sitter' 
                              ? 'No assigned pet yet' 
                              : 'No pet. Go to the profile to add a pet',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: deepRed),
                        ),
                        SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: () => _fetchPets(),
                          icon: Icon(Icons.refresh),
                          label: Text('Refresh'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: deepRed,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () async {
                    await _fetchPets();
                    if (_selectedPet != null) {
                      final petId = _selectedPet!['id']?.toString();
                      if (petId != null) {
                        await _fetchPetDataInBackground(petId);
                      }
                    }
                  },
                  color: deepRed,
                  child: SingleChildScrollView(
                    physics: AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.only(bottom: 16),
                    child: Column(
                      children: [
                      _buildPetProfileHeader(),

                      _buildPetStatsCard(),
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
                                  try {
                                    final alertService = MissingPetAlertService();
                                    alertService.clearLastMissingPostData();
                                  } catch (e) {
                                    // Error calling clearLastMissingPostData
                                  }

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
    String? locationSource;

    // Use current map location if set, otherwise prefer latest device location
    if (_currentMapLocation != null) {
      lat = _currentMapLocation!.latitude;
      lng = _currentMapLocation!.longitude;
      markerLabel = _currentMapLabel;
      markerSub = _currentMapSub;
      locationSource = 'Historical Location';
      markerWidget = Container(
        padding: EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.blue.withOpacity(0.3),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Icon(Icons.history, color: Colors.blue, size: 24),
      );
    } else if (_latestDeviceLocation != null) {
      lat = _latestDeviceLocation!.latitude;
      lng = _latestDeviceLocation!.longitude;
      locationSource = 'Live GPS';
      markerWidget = Container(
        padding: EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: deepRed.withOpacity(0.3),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Icon(Icons.gps_fixed, color: deepRed, size: 24),
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
      locationSource = 'Saved Location';
      markerWidget = Container(
        padding: EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.green.withOpacity(0.3),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Icon(Icons.pets, color: Colors.green, size: 24),
      );
      markerLabel = _selectedPet!['name']?.toString() ?? 'Pet';
      markerSub = 'Saved location';
    }

    // Agusan del Norte coordinates
    final agusanDelNorteCenter = LatLng(9.0, 125.5);

    final mapCenter = (lat != null && lng != null)
        ? LatLng(lat, lng)
        : agusanDelNorteCenter;

    // Calculate distance if we have both latest and current locations
    String? distanceInfo;
    if (_latestDeviceLocation != null && _currentMapLocation != null) {
      // Simple distance calculation (approximate)
      final latDiff = (_latestDeviceLocation!.latitude - _currentMapLocation!.latitude).abs();
      final lngDiff = (_latestDeviceLocation!.longitude - _currentMapLocation!.longitude).abs();
      final distance = (latDiff + lngDiff) * 111; // Rough km conversion
      if (distance > 0.1) {
        distanceInfo = '${distance.toStringAsFixed(1)} km from current location';
      }
    }

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [lightBlush.withOpacity(0.3), Colors.white],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            // Enhanced Header Section
            Container(
              margin: EdgeInsets.all(16),
              padding: EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [deepRed, coral],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: deepRed.withOpacity(0.3),
                    blurRadius: 15,
                    offset: Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.location_on, color: Colors.white, size: 28),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Pet Location Tracking',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              _selectedPet != null ? 'Tracking ${_selectedPet!['name'] ?? 'Pet'}' : 'No pet selected',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.white.withOpacity(0.9),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 16),
                  
                  // Status indicators
                  Row(
                    children: [
                      _buildStatusIndicator(
                        icon: Icons.gps_fixed,
                        label: 'GPS Status',
                        value: _latestDeviceLocation != null ? 'Active' : 'Inactive',
                        color: _latestDeviceLocation != null ? Colors.green : Colors.orange,
                        isActive: _latestDeviceLocation != null,
                      ),
                      SizedBox(width: 12),
                      _buildStatusIndicator(
                        icon: Icons.history,
                        label: 'History',
                        value: '${_locationHistory.length} records',
                        color: _locationHistory.isNotEmpty ? Colors.blue : Colors.grey,
                        isActive: _locationHistory.isNotEmpty,
                      ),
                    ],
                  ),
                  
                  SizedBox(height: 16),
                  
                  // Action buttons
                  Row(
                    children: [
                      Expanded(
                        flex: 1,
                        child: Container(),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: IconButton(
                          icon: Icon(Icons.refresh, color: Colors.white),
                          tooltip: 'Refresh location',
                          onPressed: () async {
                            await _fetchLatestLocationForPet();
                            await _refreshAddressesForLocationHistory();
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Row(
                                    children: [
                                      Icon(Icons.check_circle, color: Colors.white),
                                      SizedBox(width: 8),
                                      Text('Location refreshed'),
                                    ],
                                  ),
                                  backgroundColor: Colors.green,
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              );
                            }
                          },
                        ),
                      ),
                      Expanded(
                        flex: 1,
                        child: Container(),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Enhanced Map Section
            Container(
              margin: EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 15,
                    offset: Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Map header
                  Container(
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.map, color: deepRed, size: 24),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Live Map View',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: deepRed,
                                ),
                              ),
                              if (locationSource != null) ...[
                                SizedBox(height: 4),
                                Row(
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        color: locationSource == 'Live GPS' ? Colors.green :
                                               locationSource == 'Historical Location' ? Colors.blue : Colors.orange,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    SizedBox(width: 6),
                                    Text(
                                      locationSource,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                    if (distanceInfo != null) ...[
                                      SizedBox(width: 8),
                                      Text('• $distanceInfo',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        Container(
                          decoration: BoxDecoration(
                            color: deepRed.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: IconButton(
                            icon: Icon(Icons.fullscreen, color: deepRed, size: 20),
                            tooltip: 'Expand map',
                            onPressed: () => _expandMapView(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  // Map content
                  Container(
                    height: 280,
                    child: ClipRRect(
                      borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
                      child: Stack(
                        children: [
                          FlutterMap(
                            options: MapOptions(
                              initialCenter: mapCenter,
                              initialZoom: 15,
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
                                      width: 200,
                                      height: 150,
                                      child: GestureDetector(
                                        onTap: () => _expandMapView(),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            markerWidget,
                                            SizedBox(height: 8),
                                            Container(
                                              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                              decoration: BoxDecoration(
                                                color: Colors.white,
                                                borderRadius: BorderRadius.circular(12),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: Colors.black.withOpacity(0.2),
                                                    blurRadius: 8,
                                                    offset: Offset(0, 2),
                                                  ),
                                                ],
                                              ),
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    markerLabel ?? '', 
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.bold,
                                                      color: deepRed,
                                                    ),
                                                    textAlign: TextAlign.center,
                                                    maxLines: 2,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                  if (markerSub != null) ...[
                                                    SizedBox(height: 2),
                                                    Text(
                                                      markerSub, 
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        color: Colors.grey.shade600,
                                                      ),
                                                      textAlign: TextAlign.center,
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ],
                                                ],
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
                          
                          // Map controls overlay
                          Positioned(
                            right: 12,
                            top: 12,
                            child: Column(
                              children: [
                                if (_currentMapLocation != null)
                                  Container(
                                    margin: EdgeInsets.only(bottom: 8),
                                    decoration: BoxDecoration(
                                      color: Colors.blue,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: IconButton(
                                      icon: Icon(Icons.my_location, color: Colors.white, size: 20),
                                      tooltip: 'Return to live location',
                                      onPressed: () {
                                        setState(() {
                                          _currentMapLocation = null;
                                          _currentMapLabel = null;
                                          _currentMapSub = null;
                                        });
                                      },
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            
            SizedBox(height: 20),
            
            // Enhanced Location History Section
            Container(
              margin: EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 15,
                    offset: Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // History header
                  Container(
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.history, color: deepRed, size: 24),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Location History',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: deepRed,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                _locationHistory.isEmpty 
                                  ? 'No location records found'
                                  : '${_locationHistory.length} recent locations',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_locationHistory.isNotEmpty)
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.blue.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: IconButton(
                              icon: Icon(Icons.map, color: Colors.blue, size: 20),
                              tooltip: 'View all on map',
                              onPressed: () => _expandMapView(),
                            ),
                          ),
                      ],
                    ),
                  ),
                  
                  // History content
                  Container(
                    padding: EdgeInsets.all(16),
                    child: _locationHistory.isEmpty
                        ? _buildEmptyLocationState()
                        : Column(
                            children: _locationHistory.asMap().entries.map((entry) {
                              final idx = entry.key;
                              final record = entry.value;
                              final isLast = idx == _locationHistory.length - 1;
                              
                              return Column(
                                children: [
                                  _buildLocationHistoryCard(record, idx),
                                  if (!isLast) SizedBox(height: 12),
                                ],
                              );
                            }).toList(),
                          ),
                  ),
                ],
              ),
            ),
            
            SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  // Helper widget for status indicators
  Widget _buildStatusIndicator({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    required bool isActive,
  }) {
    return Expanded(
      child: Container(
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.white.withOpacity(0.3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  color: Colors.white,
                  size: 16,
                ),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withOpacity(0.9),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                fontSize: 13,
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Helper widget for empty location state
  Widget _buildEmptyLocationState() {
    return Container(
      padding: EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.location_off,
              size: 40,
              color: Colors.grey.shade400,
            ),
          ),
          SizedBox(height: 16),
          Text(
            'No Location History',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.grey.shade700,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Connect a GPS device to start tracking your pet\'s location.',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade600,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // Helper widget for location history cards
  Widget _buildLocationHistoryCard(Map<String, dynamic> record, int index) {
    final address = (record['address'] as String?)?.toString();
    final lat = record['latitude'] as double?;
    final lng = record['longitude'] as double?;
    final timestamp = record['timestamp'] as DateTime?;
    final device = record['device_mac']?.toString();
    
    // Determine location display info
    String title;
    String subtitle;
    IconData leadingIcon;
    Color iconColor;
    
    if (address != null && address.isNotEmpty) {
      title = address;
      subtitle = lat != null && lng != null 
          ? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
          : 'Address only';
      leadingIcon = Icons.location_on;
      iconColor = deepRed;
    } else if (lat != null && lng != null) {
      title = '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
      subtitle = 'Coordinates only';
      leadingIcon = Icons.my_location;
      iconColor = Colors.orange;
    } else {
      title = 'Unknown Location';
      subtitle = 'No coordinates available';
      leadingIcon = Icons.location_off;
      iconColor = Colors.grey;
    }
    
    // Calculate time ago
    String timeAgo = 'Unknown time';
    if (timestamp != null) {
      final now = DateTime.now();
      final difference = now.difference(timestamp);
      
      if (difference.inDays > 0) {
        timeAgo = '${difference.inDays} day${difference.inDays == 1 ? '' : 's'} ago';
      } else if (difference.inHours > 0) {
        timeAgo = '${difference.inHours} hour${difference.inHours == 1 ? '' : 's'} ago';
      } else if (difference.inMinutes > 0) {
        timeAgo = '${difference.inMinutes} minute${difference.inMinutes == 1 ? '' : 's'} ago';
      } else {
        timeAgo = 'Just now';
      }
    }
    
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: ListTile(
        contentPadding: EdgeInsets.all(16),
        leading: Container(
          padding: EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: iconColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            leadingIcon,
            color: iconColor,
            size: 20,
          ),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade800,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
            ),
            SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.access_time, size: 12, color: Colors.grey.shade500),
                SizedBox(width: 4),
                Text(
                  timeAgo,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade500,
                  ),
                ),
                if (device != null) ...[
                  SizedBox(width: 8),
                  Icon(Icons.device_hub, size: 12, color: Colors.grey.shade500),
                  SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      device,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
        trailing: lat != null && lng != null 
            ? Container(
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: IconButton(
                  icon: Icon(Icons.visibility, color: Colors.blue, size: 18),
                  tooltip: 'View on map',
                  onPressed: () {
                    _updateMapView(LatLng(lat, lng), title, timeAgo);
                  },
                ),
              )
            : null,
        onTap: lat != null && lng != null 
            ? () {
                _updateMapView(LatLng(lat, lng), title, timeAgo);
              }
            : null,
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

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [lightBlush.withOpacity(0.3), Colors.white],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.all(20),
        child: Column(
          children: [
            // Header Section
            Container(
              padding: EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [deepRed, coral],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: deepRed.withOpacity(0.3),
                    blurRadius: 15,
                    offset: Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        padding: EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.qr_code,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                      SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Pet ID & Contact Card',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Share your pet\'s details instantly',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.white.withOpacity(0.9),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            SizedBox(height: 24),

            // QR Code Section
            Container(
              padding: EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 20,
                    offset: Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Text(
                    'Scan QR Code',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: deepRed,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Anyone can scan to view pet information',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  SizedBox(height: 20),
                  
                  // QR Code with decorative border
                  Container(
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: deepRed.withOpacity(0.2),
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 10,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: FutureBuilder<Uint8List?>(
                      future: _generateQrBytes(payloadStr, 250.0),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done) {
                          return Container(
                            width: 250,
                            height: 250,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  CircularProgressIndicator(color: deepRed),
                                  SizedBox(height: 12),
                                  Text(
                                    'Generating QR Code...',
                                    style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }
                        if (snapshot.hasData && snapshot.data != null) {
                          return Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: deepRed.withOpacity(0.1),
                                  blurRadius: 8,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.memory(
                                snapshot.data!,
                                width: 250,
                                height: 250,
                                fit: BoxFit.contain,
                              ),
                            ),
                          );
                        }
                        return Container(
                          width: 250,
                          height: 250,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.error_outline,
                                  color: Colors.grey.shade500,
                                  size: 40,
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'QR Code Unavailable',
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),

            SizedBox(height: 20),

            // Action Buttons
            Container(
              padding: EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Quick Actions',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: deepRed,
                    ),
                  ),
                  SizedBox(height: 16),
                  
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: Icon(Icons.copy, size: 18),
                          label: Text('Copy Link'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: deepRed,
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: payloadStr));
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Row(
                                    children: [
                                      Icon(Icons.check_circle, color: Colors.white),
                                      SizedBox(width: 8),
                                      Text('Link copied to clipboard'),
                                    ],
                                  ),
                                  backgroundColor: Colors.green,
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              );
                            }
                          },
                        ),
                      ),
                      // Share action removed per request
                    ],
                  ),
                  
                  SizedBox(height: 12),
                  
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: Icon(Icons.refresh, size: 18),
                          label: Text('Regenerate'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.grey.shade700,
                            side: BorderSide(color: Colors.grey.shade400, width: 1),
                            padding: EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () {
                            setState(() {});
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Row(
                                  children: [
                                    Icon(Icons.refresh, color: Colors.white),
                                    SizedBox(width: 8),
                                    Text('QR Code regenerated'),
                                  ],
                                ),
                                backgroundColor: Colors.blue,
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      // Save action removed per request
                    ],
                  ),
                ],
              ),
            ),

            SizedBox(height: 20),

            // Information Card
            Container(
              padding: EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info, color: Colors.blue.shade700, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'How it works',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue.shade800,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  _buildInfoItem(
                    '📱',
                    'Scan with any QR reader',
                    'The QR code works with any smartphone camera or QR code app',
                  ),
                  SizedBox(height: 8),
                  _buildInfoItem(
                    '🌐',
                    'Opens web page instantly',
                    'No app installation required - works in any web browser',
                  ),
                  SizedBox(height: 8),
                  _buildInfoItem(
                    '📍',
                    'Shows essential pet info',
                    'Displays pet details, owner contact, and last known location',
                  ),
                  SizedBox(height: 8),
                  _buildInfoItem(
                    '🔒',
                    'Safe and secure',
                    'Only public pet information is shared - no private data',
                  ),
                  SizedBox(height: 16),
                  Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.8),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.link, color: Colors.blue.shade700, size: 16),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Link: $publicUrl',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blue.shade700,
                              fontFamily: 'monospace',
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
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

  // Helper method for info items in QR section
  Widget _buildInfoItem(String emoji, String title, String description) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          emoji,
          style: TextStyle(fontSize: 16),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.blue.shade800,
                ),
              ),
              SizedBox(height: 2),
              Text(
                description,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.blue.shade700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Show share dialog for QR code
  void _showShareDialog() {
    final baseBackend = backendUrl.replaceAll(RegExp(r'/analyze/?\$'), '');
    final publicUrl = '$baseBackend/pet/${_selectedPet!['id']}';
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.share, color: deepRed),
            SizedBox(width: 8),
            Text('Share Pet Info'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Share your pet\'s information with others:'),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.link, color: Colors.grey.shade600, size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      publicUrl,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: Colors.grey.shade700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: deepRed,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(context);
              // Here you could integrate with platform sharing
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Sharing feature coming soon!'),
                  backgroundColor: Colors.blue,
                ),
              );
            },
            child: Text('Share'),
          ),
        ],
      ),
    );
  }

  // Show save QR dialog
  void _showSaveQRDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.download, color: deepRed),
            SizedBox(width: 8),
            Text('Save QR Code'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Save QR code as image:'),
            SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.info_outline, color: Colors.blue, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'The QR code will be saved to your device\'s gallery.',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: deepRed,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(context);
              // Here you could implement actual saving functionality
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Save feature coming soon!'),
                  backgroundColor: Colors.blue,
                ),
              );
            },
            child: Text('Save'),
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
    final createdAt = log['created_at']?.toString();
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
      useSafeArea: true,
      builder: (_) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.75,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.white, lightBlush.withOpacity(0.3)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 20,
                spreadRadius: 5,
                offset: Offset(0, -5),
              ),
            ],
          ),
          child: Column(
            children: [
              // Handle bar
              Container(
                margin: EdgeInsets.only(top: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // Header
              Container(
                padding: EdgeInsets.all(20),
                child: Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [deepRed, coral],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(15),
                        boxShadow: [
                          BoxShadow(
                            color: deepRed.withOpacity(0.3),
                            blurRadius: 8,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.pets,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                    SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Behavior Log',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: deepRed,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            DateFormat('EEEE, MMMM d, yyyy').format(date),
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey.shade600,
                            ),
                          ),
                          if (createdAt != null) ...[
                            SizedBox(height: 2),
                            Text(
                              'Logged: ${_formatLoggedTime(createdAt)}',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close, color: Colors.grey.shade600),
                      onPressed: () => Navigator.pop(context),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.grey.shade100,
                        shape: CircleBorder(),
                      ),
                    ),
                  ],
                ),
              ),

              // Content
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      // Mood Section
                      _buildDetailCard(
                        title: 'Mood',
                        icon: Icons.mood,
                        iconColor: Colors.orange,
                        value: mood.isEmpty ? 'Not recorded' : mood,
                        emoji: mood.isNotEmpty ? _moodEmojis[mood] : null,
                        isEmpty: mood.isEmpty,
                      ),

                      SizedBox(height: 16),

                      // Activity Section
                      _buildDetailCard(
                        title: 'Activity Level',
                        icon: Icons.directions_run, 
                        iconColor: Colors.green,
                        value: activity.isEmpty ? 'Not recorded' : activity,
                        emoji: activity.isNotEmpty ? _activityEmojis[activity] : null,
                        isEmpty: activity.isEmpty,
                      ),

                      SizedBox(height: 16),

                      // Sleep Section
                      _buildDetailCard(
                        title: 'Sleep Hours',
                        icon: Icons.bedtime,
                        iconColor: Colors.blue,
                        value: sleep.isEmpty ? 'Not recorded' : '${sleep} hours',
                        subtitle: sleep.isNotEmpty ? _getSleepFeedback(double.tryParse(sleep) ?? 0) : null,
                        isEmpty: sleep.isEmpty,
                      ),

                      SizedBox(height: 16),

                      // Notes Section
                      if (notes.isNotEmpty) ...[
                        _buildDetailCard(
                          title: 'Notes',
                          icon: Icons.note_alt,
                          iconColor: Colors.purple,
                          value: notes,
                          isNote: true,
                          isEmpty: false,
                        ),
                        SizedBox(height: 16),
                      ],

                      // Health Insights
                      _buildHealthInsights(mood, activity, sleep),

                      SizedBox(height: 20),
                    ],
                  ),
                ),
              ),

              // Action buttons
              Container(
                padding: EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: Offset(0, -5),
                    ),
                  ],
                ),
                child: SafeArea(
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: Icon(Icons.edit, color: deepRed, size: 20),
                          label: Text(
                            'Edit Log',
                            style: TextStyle(
                              color: deepRed,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: deepRed, width: 2),
                            padding: EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
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
                      SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: Icon(Icons.delete, size: 20),
                          label: Text(
                            'Delete Log',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          onPressed: () => _confirmDeleteBehaviorLog(context, log),
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

  // Helper widget for detail cards
  Widget _buildDetailCard({
    required String title,
    required IconData icon,
    required Color iconColor,
    required String value,
    String? emoji,
    String? subtitle,
    bool isNote = false,
    bool isEmpty = false,
  }) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isEmpty ? Colors.grey.shade300 : iconColor.withOpacity(0.3),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isEmpty ? Colors.grey.shade100 : iconColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  icon,
                  color: isEmpty ? Colors.grey.shade400 : iconColor,
                  size: 20,
                ),
              ),
              SizedBox(width: 12),
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isEmpty ? Colors.grey.shade600 : Colors.grey.shade800,
                ),
              ),
              if (emoji != null) ...[
                Spacer(),
                Text(
                  emoji,
                  style: TextStyle(fontSize: 24),
                ),
              ],
            ],
          ),
          SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              fontSize: isNote ? 14 : 16,
              color: isEmpty ? Colors.grey.shade500 : Colors.grey.shade700,
              height: isNote ? 1.4 : 1.2,
            ),
          ),
          if (subtitle != null) ...[
            SizedBox(height: 8),
            Container(
              padding: EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: iconColor == Colors.orange ? Colors.orange.shade700 :
                         iconColor == Colors.green ? Colors.green.shade700 :
                         iconColor == Colors.blue ? Colors.blue.shade700 :
                         iconColor == Colors.purple ? Colors.purple.shade700 :
                         iconColor.withOpacity(0.8),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Health insights widget
  Widget _buildHealthInsights(String mood, String activity, String sleep) {
    List<Widget> insights = [];
    
    // Sleep insights
    final sleepHours = double.tryParse(sleep);
    if (sleepHours != null) {
      if (sleepHours < 6) {
        insights.add(_buildInsightItem(
          'Low Sleep Detected',
          'Monitor for signs of fatigue or health issues.',
          Icons.warning,
          Colors.red,
        ));
      } else if (sleepHours > 16) {
        insights.add(_buildInsightItem(
          'High Sleep Duration',
          'Consider checking for illness or stress factors.',
          Icons.info,
          Colors.orange,
        ));
      }
    }

    // Activity insights
    if (activity == 'Low' && mood == 'Lethargic') {
      insights.add(_buildInsightItem(
        'Low Energy Pattern',
        'Consider encouraging more activity or consult a vet.',
        Icons.trending_down,
        Colors.orange,
      ));
    } else if (activity == 'High' && mood == 'Happy') {
      insights.add(_buildInsightItem(
        'Great Energy Balance',
        'Your pet seems to be in excellent spirits!',
        Icons.trending_up,
        Colors.green,
      ));
    }

    // Mood insights
    if (mood == 'Anxious' || mood == 'Aggressive') {
      insights.add(_buildInsightItem(
        'Mood Concern',
        'Monitor behavior patterns and consider environmental factors.',
        Icons.psychology,
        Colors.red,
      ));
    }

    if (insights.isEmpty) {
      insights.add(_buildInsightItem(
        'Normal Patterns',
        'All logged behaviors appear within normal ranges.',
        Icons.check_circle,
        Colors.green,
      ));
    }

    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.health_and_safety, color: Colors.blue.shade700, size: 20),
              SizedBox(width: 8),
              Text(
                'Health Insights',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue.shade800,
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          ...insights,
        ],
      ),
    );
  }

  Widget _buildInsightItem(String title, String description, IconData icon, Color color) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 16),
          SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: color == Colors.orange ? Colors.orange.shade800 :
                           color == Colors.green ? Colors.green.shade800 :
                           color == Colors.blue ? Colors.blue.shade800 :
                           color == Colors.purple ? Colors.purple.shade800 :
                           color == Colors.red ? Colors.red.shade800 :
                           color.withOpacity(0.9),
                  ),
                ),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    color: color == Colors.orange ? Colors.orange.shade700 :
                           color == Colors.green ? Colors.green.shade700 :
                           color == Colors.blue ? Colors.blue.shade700 :
                           color == Colors.purple ? Colors.purple.shade700 :
                           color == Colors.red ? Colors.red.shade700 :
                           color.withOpacity(0.8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Helper method to format logged time
  String _formatLoggedTime(String createdAt) {
    try {
      final dateTime = DateTime.parse(createdAt);
      final now = DateTime.now();
      final difference = now.difference(dateTime);
      
      if (difference.inDays > 0) {
        return '${difference.inDays} day${difference.inDays == 1 ? '' : 's'} ago';
      } else if (difference.inHours > 0) {
        return '${difference.inHours} hour${difference.inHours == 1 ? '' : 's'} ago';
      } else if (difference.inMinutes > 0) {
        return '${difference.inMinutes} minute${difference.inMinutes == 1 ? '' : 's'} ago';
      } else {
        return 'Just now';
      }
    } catch (e) {
      return 'Recently';
    }
  }

  // Enhanced delete confirmation
  Future<void> _confirmDeleteBehaviorLog(BuildContext context, Map<String, dynamic> log) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.warning, color: Colors.orange),
            SizedBox(width: 8),
            Text('Delete Behavior Log?'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This will permanently remove this behavior log entry.'),
            SizedBox(height: 12),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'This action will:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                  SizedBox(height: 4),
                  Text('• Remove the log from your calendar', style: TextStyle(fontSize: 12)),
                  Text('• Update sleep predictions', style: TextStyle(fontSize: 12)),
                  Text('• Recalculate behavior analytics', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete'),
          ),
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
        
        // Refresh everything
        await Future.wait([
          _fetchBehaviorDates(),
          _fetchAnalyzeFromBackend(),
          _fetchLatestAnalysis(),
        ]);
        
        if (mounted) {
          ScaffoldMessenger.of(this.context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.white),
                  SizedBox(width: 8),
                  Text('Behavior log deleted successfully'),
                ],
              ),
              backgroundColor: Colors.green,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(this.context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Icon(Icons.error, color: Colors.white),
                  SizedBox(width: 8),
                  Expanded(child: Text('Failed to delete: ${e.toString()}')),
                ],
              ),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
        }
      }
    }
  }

  Widget _buildBehaviorTab() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        child: Column(
          children: [
            // Enhanced Calendar Section
            Container(
              margin: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  )
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: TableCalendar(
                  firstDay: DateTime.utc(2020, 1, 1),
                  lastDay: DateTime.utc(2030, 12, 31),
                  focusedDay: _focusedDay,
                  calendarFormat: _calendarFormat,
                  availableCalendarFormats: const { CalendarFormat.month: 'Month' },
                  headerStyle: HeaderStyle(
                    formatButtonVisible: false,
                    titleCentered: true,
                    titleTextStyle: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: deepRed,
                    ),
                    leftChevronIcon: Icon(Icons.chevron_left, color: deepRed),
                    rightChevronIcon: Icon(Icons.chevron_right, color: deepRed),
                    decoration: BoxDecoration(
                      color: lightBlush,
                    ),
                  ),
                  calendarStyle: CalendarStyle(
                    outsideDaysVisible: false,
                    weekendTextStyle: TextStyle(color: coral),
                    holidayTextStyle: TextStyle(color: coral),
                    selectedDecoration: BoxDecoration(
                      color: deepRed,
                      shape: BoxShape.circle,
                    ),
                    todayDecoration: BoxDecoration(
                      color: coral.withOpacity(0.7),
                      shape: BoxShape.circle,
                    ),
                    markerDecoration: BoxDecoration(
                      color: peach,
                      shape: BoxShape.circle,
                    ),
                    defaultTextStyle: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                  eventLoader: (day) {
                    final key = DateTime(day.year, day.month, day.day);
                    return _events[key] ?? [];
                  },
                  calendarBuilders: CalendarBuilders(
                    markerBuilder: (context, date, events) {
                      if (events.isNotEmpty) {
                        return Positioned(
                          bottom: 4,
                          child: Container(
                            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: deepRed.withOpacity(0.8),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              events.join(' '),
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white,
                              ),
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
              ),
            ),
            
            SizedBox(height: 16),
            
            // Enhanced Health Status Section
            Container(
              margin: EdgeInsets.symmetric(horizontal: 8),
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: _isUnhealthy 
                    ? [deepRed.withOpacity(0.1), coral.withOpacity(0.1)]
                    : [Colors.green.withOpacity(0.1), Colors.lightGreen.withOpacity(0.1)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isUnhealthy ? deepRed.withOpacity(0.3) : Colors.green.withOpacity(0.3),
                  width: 2,
                ),
              ),
              child: InkWell(
                onTap: _isUnhealthy ? () => _showHealthDetailsDialog() : null,
                borderRadius: BorderRadius.circular(16),
                child: Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _isUnhealthy ? deepRed : Colors.green,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _isUnhealthy ? Icons.warning : Icons.favorite,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                    SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isUnhealthy ? "Health Alert" : "Healthy Status",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: _isUnhealthy ? deepRed : Colors.green.shade700,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            _isUnhealthy
                                ? "Illness risk: ${_illnessRisk ?? 'Unknown'}"
                                : "No illness predicted — pet appears healthy",
                            style: TextStyle(
                              fontSize: 14,
                              color: _isUnhealthy ? deepRed.withOpacity(0.8) : Colors.green.shade600,
                            ),
                          ),
                          if (_isUnhealthy)
                            Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: Text(
                                'Tap for details',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: deepRed.withOpacity(0.6),
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (_isUnhealthy)
                      Icon(
                        Icons.arrow_forward_ios,
                        color: deepRed,
                        size: 16,
                      ),
                  ],
                ),
              ),
            ),
            
            // Enhanced Latest Analysis Section
            if (_prediction != null || _loadingAnalysisData) ...[
              SizedBox(height: 16),
              Container(
                margin: EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    )
                  ],
                ),
                child: _loadingAnalysisData
                    ? _buildAnalysisLoadingSkeleton()
                    : _buildEnhancedAnalysisContent(),
              ),
            ],

            // Enhanced Sleep Forecast and Analytics
            if (_sleepTrend.isNotEmpty || _loadingAnalysisData) ...[
              SizedBox(height: 16),
              Container(
                margin: EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    )
                  ],
                ),
                child: _loadingAnalysisData
                    ? _buildChartLoadingSkeleton()
                    : _buildEnhancedSleepChart(),
              ),
            ],

            // Enhanced Mood and Activity Analytics
            if ((_moodProb.isNotEmpty || _activityProb.isNotEmpty) || _loadingAnalysisData) ...[
              SizedBox(height: 16),
              Container(
                margin: EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    )
                  ],
                ),
                child: _loadingAnalysisData
                    ? _buildDistributionLoadingSkeleton()
                    : _buildEnhancedMoodActivityAnalytics(),
              ),
            ],

            // Add bottom spacing
            SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  // Enhanced analysis content
  Widget _buildEnhancedAnalysisContent() {
    return Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: coral.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.analytics, color: deepRed, size: 20),
              ),
              SizedBox(width: 12),
              Text(
                "Latest Analysis",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  color: deepRed,
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
          
          if (_prediction != null) ...[
            _buildAnalysisCard(
              icon: Icons.trending_up,
              title: "Prediction",
              content: _prediction!,
              color: Colors.blue,
            ),
            SizedBox(height: 12),
          ],
          
          if (_recommendation != null) ...[
            _buildAnalysisCard(
              icon: Icons.lightbulb,
              title: "Recommendation",
              content: _recommendation!,
              color: Colors.orange,
            ),
            SizedBox(height: 12),
          ],
          
          if (_backendSleepForecast.isNotEmpty) ...[
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: deepRed.withOpacity(0.06),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: deepRed.withOpacity(0.18)),
              ),
              child: Row(
                children: [
                  Icon(Icons.bedtime, color: deepRed, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Sleep Forecast (next 7 days)",
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        SizedBox(height: 4),
                        Text(
                          "${_backendSleepForecast.map((d) => d.toStringAsFixed(1)).join(', ')} hours",
                          style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          
          // Care Tips (only when risk is bad: medium/high)
          if (_isUnhealthy && (_careActions.isNotEmpty || _careExpectations.isNotEmpty)) ...[
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: deepRed.withOpacity(0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: deepRed.withOpacity(0.2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.medical_services, color: deepRed, size: 20),
                      SizedBox(width: 8),
                      Text(
                        "Care Tips",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: deepRed,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  
                  if (_careActions.isNotEmpty) ...[
                    Text("What to do", style: TextStyle(fontWeight: FontWeight.w600)),
                    SizedBox(height: 6),
                    ..._careActions.take(6).map((action) => Padding(
                      padding: const EdgeInsets.only(bottom: 4.0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.check_circle, size: 16, color: deepRed),
                          SizedBox(width: 8),
                          Expanded(child: Text(action, style: TextStyle(fontSize: 14))),
                        ],
                      ),
                    )),
                  ],
                  
                  if (_careExpectations.isNotEmpty) ...[
                    if (_careActions.isNotEmpty) SizedBox(height: 12),
                    Text("What to expect", style: TextStyle(fontWeight: FontWeight.w600)),
                    SizedBox(height: 6),
                    ..._careExpectations.take(6).map((expectation) => Padding(
                      padding: const EdgeInsets.only(bottom: 4.0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info, size: 16, color: coral),
                          SizedBox(width: 8),
                          Expanded(child: Text(expectation, style: TextStyle(fontSize: 14))),
                        ],
                      ),
                    )),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Helper widget for analysis cards
  Widget _buildAnalysisCard({
    required IconData icon,
    required String title,
    required String content,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  content,
                  style: TextStyle(fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Enhanced sleep chart
  Widget _buildEnhancedSleepChart() {
    final hasData = _sleepTrend.isNotEmpty && _backendSleepForecast.isNotEmpty;
    
    return Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Section
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  deepRed.withOpacity(0.06),
                  coral.withOpacity(0.04),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: deepRed.withOpacity(0.18)),
            ),
            child: Row(
              children: [
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: deepRed,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: deepRed.withOpacity(0.3),
                        blurRadius: 8,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(Icons.bedtime, color: Colors.white, size: 24),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Sleep Forecast",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 20,
                          color: deepRed,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        hasData 
                          ? "Next 7 days predicted sleep pattern"
                          : "Need more data for accurate predictions",
                        style: TextStyle(
                          fontSize: 14,
                          color: coral,
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    // Forecast accuracy indicator
                    if (hasData) ...[
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _getForecastAccuracyColor().withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: _getForecastAccuracyColor()),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _getForecastAccuracyIcon(),
                              size: 14,
                              color: _getForecastAccuracyColor(),
                            ),
                            SizedBox(width: 4),
                            Text(
                              _getForecastAccuracyText(),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: _getForecastAccuracyColor(),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: 8),
                    ],
                    IconButton(
                      icon: Icon(Icons.info_outline, color: coral),
                      onPressed: () => _showSleepDebugDialog(),
                      tooltip: 'How is this predicted?',
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.white.withOpacity(0.8),
                        shape: CircleBorder(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          
          SizedBox(height: 16),

          // Chart Section
          if (hasData) ...[
            Container(
              height: 280,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade200),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  children: [
                    // Chart legend
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildLegendItem(
                          color: Colors.blue.shade600,
                          label: "Predicted Sleep",
                          icon: Icons.trending_up,
                        ),
                        SizedBox(width: 24),
                        _buildLegendItem(
                          color: Colors.grey.shade400,
                          label: "Optimal Range",
                          icon: Icons.horizontal_rule,
                        ),
                      ],
                    ),
                    SizedBox(height: 16),
                    
                    // Chart
                    Expanded(
                      child: LineChart(
                        LineChartData(
                          minY: 0,
                          maxY: 24,
                          titlesData: FlTitlesData(
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 45,
                                interval: 4,
                                getTitlesWidget: (value, meta) {
                                  return Padding(
                                    padding: EdgeInsets.only(right: 8),
                                    child: Text(
                                      '${value.toInt()}h',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade600,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 35,
                                getTitlesWidget: (value, meta) {
                                  int idx = value.toInt();
                                  if (idx >= 0 && idx < _sleepTrend.length) {
                                    final date = _selectedDate != null
                                        ? _selectedDate!.add(Duration(days: idx))
                                        : DateTime.now().add(Duration(days: idx));
                                    
                                    return Padding(
                                      padding: EdgeInsets.only(top: 8),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            DateFormat('EEE').format(date),
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: Colors.grey.shade600,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          Text(
                                            DateFormat('M/d').format(date),
                                            style: TextStyle(
                                              fontSize: 9,
                                              color: Colors.grey.shade500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }
                                  return SizedBox.shrink();
                                },
                              ),
                            ),
                            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          ),
                          gridData: FlGridData(
                            show: true,
                            drawHorizontalLine: true,
                            drawVerticalLine: false,
                            horizontalInterval: 4,
                            getDrawingHorizontalLine: (value) {
                              // Highlight optimal sleep range (8-12 hours for most pets)
                              if (value == 8 || value == 12) {
                                return FlLine(
                                  color: Colors.green.withOpacity(0.3),
                                  strokeWidth: 2,
                                  dashArray: [5, 5],
                                );
                              }
                              return FlLine(
                                color: Colors.grey.shade200,
                                strokeWidth: 1,
                              );
                            },
                          ),
                          borderData: FlBorderData(
                            show: true,
                            border: Border.all(color: Colors.grey.shade300, width: 1),
                          ),
                          lineBarsData: [
                            // Main forecast line
                            LineChartBarData(
                              spots: List.generate(
                                _sleepTrend.length,
                                (i) => FlSpot(i.toDouble(), _sleepTrend[i]),
                              ),
                              isCurved: true,
                              curveSmoothness: 0.3,
                              color: Colors.blue.shade600,
                              barWidth: 4,
                              dotData: FlDotData(
                                show: true,
                                getDotPainter: (spot, percent, barData, index) {
                                  final value = spot.y;
                                  Color dotColor;
                                  
                                  // Color code based on sleep health
                                  if (value >= 8 && value <= 12) {
                                    dotColor = Colors.green;
                                  } else if (value >= 6 && value <= 14) {
                                    dotColor = Colors.orange;
                                  } else {
                                    dotColor = Colors.red;
                                  }
                                  
                                  return FlDotCirclePainter(
                                    radius: 6,
                                    color: Colors.white,
                                    strokeWidth: 3,
                                    strokeColor: dotColor,
                                  );
                                },
                              ),
                              belowBarData: BarAreaData(
                                show: true,
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.blue.shade600.withOpacity(0.3),
                                    Colors.blue.shade600.withOpacity(0.1),
                                  ],
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                ),
                              ),
                            ),
                          ],
                          lineTouchData: LineTouchData(
                            enabled: true,
                            touchTooltipData: LineTouchTooltipData(
                              getTooltipColor: (touchedSpot) => Colors.blue.shade700,
                              getTooltipItems: (touchedSpots) {
                                return touchedSpots.map((spot) {
                                  final date = _selectedDate != null
                                      ? _selectedDate!.add(Duration(days: spot.x.toInt()))
                                      : DateTime.now().add(Duration(days: spot.x.toInt()));
                                  return LineTooltipItem(
                                    '${DateFormat('MMM d').format(date)}\n${spot.y.toStringAsFixed(1)} hours',
                                    TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                    ),
                                  );
                                }).toList();
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
            SizedBox(height: 16),
            
            // Sleep insights section
            _buildSleepInsights(),
          ] else ...[
            // No data state
            Container(
              height: 200,
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.show_chart,
                      size: 48,
                      color: Colors.grey.shade400,
                    ),
                    SizedBox(height: 12),
                    Text(
                      'No Sleep Data Yet',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Log some behavior data to see\nsleep predictions and trends',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade500,
                      ),
                    ),
                    SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: () => _showBehaviorModal(context, DateTime.now()),
                      icon: Icon(Icons.add),
                      label: Text('Log Behavior'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: deepRed,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Helper widget for chart legend items
  Widget _buildLegendItem({
    required Color color,
    required String label,
    required IconData icon,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 16),
        SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey.shade700,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  // Sleep insights section
  Widget _buildSleepInsights() {
    if (_sleepTrend.isEmpty) return SizedBox.shrink();
    
    final avgSleep = _sleepTrend.reduce((a, b) => a + b) / _sleepTrend.length;
    final minSleep = _sleepTrend.reduce((a, b) => a < b ? a : b);
    final maxSleep = _sleepTrend.reduce((a, b) => a > b ? a : b);
    final sleepVariation = maxSleep - minSleep;
    
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: coral.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: coral.withOpacity(0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.analytics, color: deepRed, size: 20),
              SizedBox(width: 8),
              Text(
                'Sleep Insights',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: deepRed,
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          
          Row(
            children: [
              Expanded(
                child: _buildInsightCard(
                  'Average',
                  '${avgSleep.toStringAsFixed(1)}h',
                  Icons.timeline,
                  _getSleepHealthColor(avgSleep),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: _buildInsightCard(
                  'Range',
                  '${minSleep.toStringAsFixed(1)}-${maxSleep.toStringAsFixed(1)}h',
                  Icons.swap_vert,
                  _getVariationColor(sleepVariation),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: _buildInsightCard(
                  'Trend',
                  _getSleepTrend(),
                  _getSleepTrendIcon(),
                  _getSleepTrendColor(),
                ),
              ),
            ],
          ),
          
          if (_getSleepRecommendation().isNotEmpty) ...[
            SizedBox(height: 12),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.9),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: deepRed.withOpacity(0.18)),
              ),
              child: Row(
                children: [
                  Icon(Icons.lightbulb, color: peach, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _getSleepRecommendation(),
                      style: TextStyle(
                        fontSize: 13,
                        color: deepRed,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Helper widget for insight cards
  Widget _buildInsightCard(String title, String value, IconData icon, Color color) {
    final bool isTrend = title.toLowerCase() == 'trend';
    return Container(
      padding: isTrend ? EdgeInsets.symmetric(vertical: 8, horizontal: 8) : EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: isTrend ? 16 : 18),
          SizedBox(height: isTrend ? 2 : 4),
          // For the compact 'Trend' card constrain the height and use FittedBox
          // so single-word values like "Stable"/"Increasing"/"Decreasing"
          // always fit neatly inside the smaller box.
          if (isTrend)
            SizedBox(
              height: 22,
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                ),
              ),
            )
          else
            Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }

  // Helper methods for sleep analysis
  Color _getForecastAccuracyColor() {
    final dataPoints = _sleepTrend.length;
    if (dataPoints >= 7) return Colors.green;
    if (dataPoints >= 4) return Colors.orange;
    return Colors.red;
  }

  IconData _getForecastAccuracyIcon() {
    final dataPoints = _sleepTrend.length;
    if (dataPoints >= 7) return Icons.check_circle;
    if (dataPoints >= 4) return Icons.warning;
    return Icons.error;
  }

  String _getForecastAccuracyText() {
    final dataPoints = _sleepTrend.length;
    if (dataPoints >= 7) return 'High';
    if (dataPoints >= 4) return 'Medium';
    return 'Low';
  }

  Color _getSleepHealthColor(double hours) {
    if (hours >= 8 && hours <= 12) return Colors.green;
    if (hours >= 6 && hours <= 14) return Colors.orange;
    return Colors.red;
  }

  Color _getVariationColor(double variation) {
    if (variation <= 2) return Colors.green;
    if (variation <= 4) return Colors.orange;
    return Colors.red;
  }

  String _getSleepTrend() {
    if (_sleepTrend.length < 2) return 'N/A';
    final first = _sleepTrend.first;
    final last = _sleepTrend.last;
    final diff = last - first;
    
    if (diff.abs() < 0.5) return 'Stable';
    return diff > 0 ? 'Increasing' : 'Decreasing';
  }

  IconData _getSleepTrendIcon() {
    if (_sleepTrend.length < 2) return Icons.help;
    final first = _sleepTrend.first;
    final last = _sleepTrend.last;
    final diff = last - first;
    
    if (diff.abs() < 0.5) return Icons.trending_flat;
    return diff > 0 ? Icons.trending_up : Icons.trending_down;
  }

  Color _getSleepTrendColor() {
    if (_sleepTrend.length < 2) return Colors.grey;
    final first = _sleepTrend.first;
    final last = _sleepTrend.last;
    final diff = last - first;
    
    if (diff.abs() < 0.5) return Colors.blue;
    
    // Trend towards optimal range (8-12h) is good
    final avgCurrent = _sleepTrend.reduce((a, b) => a + b) / _sleepTrend.length;
    if (avgCurrent < 8 && diff > 0) return Colors.green; // increasing when low
    if (avgCurrent > 12 && diff < 0) return Colors.green; // decreasing when high
    if (avgCurrent >= 8 && avgCurrent <= 12) return Colors.green; // stable in range
    
    return Colors.orange;
  }

  String _getSleepRecommendation() {
    if (_sleepTrend.isEmpty) return '';
    
    final avgSleep = _sleepTrend.reduce((a, b) => a + b) / _sleepTrend.length;
    final variation = _sleepTrend.length > 1 ? 
      (_sleepTrend.reduce((a, b) => a > b ? a : b) - _sleepTrend.reduce((a, b) => a < b ? a : b)) : 0.0;
    
    if (avgSleep < 6) {
      return 'Sleep seems quite low. Monitor for lethargy or health changes.';
    } else if (avgSleep > 16) {
      return 'Sleep seems high. Consider checking for illness or stress.';
    } else if (variation > 4) {
      return 'Sleep pattern is inconsistent. Try to maintain a regular routine.';
    } else if (avgSleep >= 8 && avgSleep <= 12 && variation <= 2) {
      return 'Excellent sleep pattern! Keep up the good routine.';
    }
    
    return 'Sleep pattern looks normal. Continue monitoring.';
  }

  // Debug dialog to explain sleep predictions
  Future<void> _showSleepDebugDialog() async {
    if (_selectedPet == null) return;
    
    try {
      final petId = _selectedPet!['id'];
      final debugUrl = backendUrl.replaceAll('/analyze', '/debug_sleep');
      
      final response = await http.post(
        Uri.parse(debugUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'pet_id': petId}),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _showEnhancedSleepDebugInfo(data);
      } else {
        _showEnhancedSimpleSleepInfo();
      }
    } catch (e) {
      _showEnhancedSimpleSleepInfo();
    }
  }
  
  void _showEnhancedSleepDebugInfo(Map<String, dynamic> debugData) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          width: MediaQuery.of(context).size.width * 0.9,
          height: MediaQuery.of(context).size.height * 0.8,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [deepRed.withOpacity(0.06), coral.withOpacity(0.04)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              // Header
              Container(
                padding: EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [deepRed, coral],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.psychology, color: Colors.white, size: 24),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Sleep Prediction Analysis',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),

              // Content
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (debugData['historical_data'] != null) ...[
                        _buildDebugSection(
                          title: 'Historical Sleep Data',
                          icon: Icons.history,
                          iconColor: Colors.green,
                          child: Column(
                            children: [
                              _buildDebugMetric(
                                'Logged Entries',
                                '${debugData['historical_data']['count']}',
                                _getDataQualityColor(debugData['historical_data']['count'] ?? 0),
                                Icons.dataset,
                              ),
                              SizedBox(height: 8),
                              _buildDebugMetric(
                                'Average Sleep',
                                '${debugData['historical_data']['statistics']['average']}h',
                                Colors.blue,
                                Icons.bedtime,
                              ),
                              SizedBox(height: 8),
                              _buildDebugMetric(
                                'Sleep Range',
                                '${debugData['historical_data']['statistics']['min']}h - ${debugData['historical_data']['statistics']['max']}h',
                                Colors.purple,
                                Icons.swap_vert,
                              ),
                              SizedBox(height: 8),
                              _buildDebugMetric(
                                'Pattern Variation',
                                '${debugData['historical_data']['statistics']['variation_level']}',
                                _getVariationStatusColor(debugData['historical_data']['statistics']['variation_level']),
                                Icons.trending_up,
                              ),
                            ],
                          ),
                        ),
                        SizedBox(height: 16),
                      ],

                      // Accuracy Tips Section
                      _buildDebugSection(
                        title: 'Improving Accuracy',
                        icon: Icons.tips_and_updates,
                        iconColor: Colors.orange,
                        child: Column(
                          children: [
                            _buildRecommendationCard(
                              'Log Consistently',
                              'Record sleep data for more than 8 days to enable advanced AI predictions',
                              Icons.event_repeat,
                              Colors.green,
                            ),
                            SizedBox(height: 8),
                            _buildRecommendationCard(
                              'Vary Your Entries',
                              'Record actual sleep patterns - consistent patterns may show flat forecasts',
                              Icons.shuffle,
                              Colors.blue,
                            ),
                            SizedBox(height: 8),
                            _buildRecommendationCard(
                              'More Data = Better Results',
                              'Current forecasts adapt to your pet\'s unique patterns over time',
                              Icons.timeline,
                              Colors.purple,
                            ),
                          ],
                        ),
                      ),

                      SizedBox(height: 20),

                      // Footer note
                      Container(
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade50,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.amber.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.lightbulb, color: Colors.amber.shade700),
                            SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Predictions become more accurate over time. Keep logging behavior for the best results!',
                                style: TextStyle(
                                  color: Colors.amber.shade800,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  void _showEnhancedSimpleSleepInfo() {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          width: MediaQuery.of(context).size.width * 0.9,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [deepRed.withOpacity(0.06), coral.withOpacity(0.04)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Container(
                padding: EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [deepRed, coral],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.bedtime, color: Colors.white, size: 24),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Sleep Forecast Info',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),

              // Content
              Padding(
                padding: EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildInfoCard(
                      'What is Sleep Forecasting?',
                      'Our AI analyzes your pet\'s behavior patterns to predict future sleep needs and identify potential health trends.',
                      Icons.auto_graph,
                      Colors.blue,
                    ),
                    SizedBox(height: 16),
                    _buildInfoCard(
                      'How It Works',
                      'We find correlations between mood, activity, and sleep patterns. The more data you provide, the more accurate predictions become.',
                      Icons.psychology,
                      Colors.green,
                    ),
                    SizedBox(height: 16),
                    _buildInfoCard(
                      'Getting Started',
                      'Start logging your pet\'s daily behavior. After 8+ days, you\'ll see personalized predictions and pattern analysis.',
                      Icons.play_circle_filled,
                      Colors.orange,
                    ),
                    SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _showBehaviorModal(context, DateTime.now());
                        },
                        icon: Icon(Icons.add),
                        label: Text('Start Logging Behavior'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: deepRed,
                          foregroundColor: Colors.white,
                          padding: EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Helper widgets for debug modal
  Widget _buildDebugSection({
    required String title,
    required IconData icon,
    required Color iconColor,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.1),
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                Icon(icon, color: iconColor, size: 20),
                SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: iconColor == Colors.orange ? Colors.orange.shade800 :
                           iconColor == Colors.green ? Colors.green.shade800 :
                           iconColor == Colors.blue ? Colors.blue.shade800 :
                           iconColor == Colors.purple ? Colors.purple.shade800 :
                           iconColor == Colors.red ? Colors.red.shade800 :
                           iconColor.withOpacity(0.9),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.all(16),
            child: child,
          ),
        ],
      ),
    );
  }

  Widget _buildDebugMetric(String label, String value, Color color, IconData icon) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
          ),
          Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecommendationCard(String title, String description, IconData icon, Color color) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: color == Colors.orange ? Colors.orange.shade800 :
                           color == Colors.green ? Colors.green.shade800 :
                           color == Colors.blue ? Colors.blue.shade800 :
                           color == Colors.purple ? Colors.purple.shade800 :
                           color == Colors.red ? Colors.red.shade800 :
                           color.withOpacity(0.9),
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    color: color == Colors.orange ? Colors.orange.shade700 :
                           color == Colors.green ? Colors.green.shade700 :
                           color == Colors.blue ? Colors.blue.shade700 :
                           color == Colors.purple ? Colors.purple.shade700 :
                           color == Colors.red ? Colors.red.shade700 :
                           color.withOpacity(0.8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard(String title, String description, IconData icon, Color color) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 5,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: color == Colors.orange ? Colors.orange.shade800 :
                           color == Colors.green ? Colors.green.shade800 :
                           color == Colors.blue ? Colors.blue.shade800 :
                           color == Colors.purple ? Colors.purple.shade800 :
                           color == Colors.red ? Colors.red.shade800 :
                           color.withOpacity(0.9),
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Helper methods for debug modal
  Color _getDataQualityColor(int dataPoints) {
    if (dataPoints >= 14) return Colors.green;
    if (dataPoints >= 7) return Colors.orange;
    return Colors.red;
  }

  Color _getVariationStatusColor(String variation) {
    switch (variation.toLowerCase()) {
      case 'low':
        return Colors.green;
      case 'medium':
        return Colors.orange;
      case 'high':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  // Show detailed health information when health alert is tapped
  void _showHealthDetailsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.health_and_safety, color: deepRed, size: 24),
            SizedBox(width: 8),
            Text(
              'Health Alert Details',
              style: TextStyle(color: deepRed, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Risk Level
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: deepRed.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: deepRed.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Risk Level: ${_illnessRisk?.toUpperCase() ?? 'UNKNOWN'}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: deepRed,
                        fontSize: 16,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      _getRiskDescription(),
                      style: TextStyle(fontSize: 14),
                    ),
                  ],
                ),
              ),
              
              SizedBox(height: 16),
              
              // Care Actions
              if (_careActions.isNotEmpty) ...[
                Text(
                  '🩺 Immediate Actions',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: deepRed,
                  ),
                ),
                SizedBox(height: 8),
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.withOpacity(0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _careActions.map((action) => Padding(
                      padding: const EdgeInsets.only(bottom: 6.0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.check_circle, size: 16, color: Colors.blue),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              action,
                              style: TextStyle(fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    )).toList(),
                  ),
                ),
                SizedBox(height: 16),
              ],
              
              // Expectations
              if (_careExpectations.isNotEmpty) ...[
                Text(
                  '📋 What to Expect',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Colors.orange.shade700,
                  ),
                ),
                SizedBox(height: 8),
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.withOpacity(0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _careExpectations.map((expectation) => Padding(
                      padding: const EdgeInsets.only(bottom: 6.0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline, size: 16, color: Colors.orange.shade700),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              expectation,
                              style: TextStyle(fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    )).toList(),
                  ),
                ),
                SizedBox(height: 16),
              ],
              
              // General advice
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.lightbulb_outline, color: Colors.amber.shade700, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Important Reminder',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.amber.shade700,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                      'This prediction is based on behavior patterns and should not replace professional veterinary advice. If symptoms persist or worsen, please consult a veterinarian immediately.',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade700,
                        fontStyle: FontStyle.italic,
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
            onPressed: () => Navigator.pop(context),
            child: Text('Close'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _showVetContactOptions();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: deepRed,
              foregroundColor: Colors.white,
            ),
            child: Text('Find Vet'),
          ),
        ],
      ),
    );
  }

  // Helper method to get risk description
  String _getRiskDescription() {
    switch (_illnessRisk?.toLowerCase()) {
      case 'high':
        return 'Your pet shows patterns that may indicate potential health issues. Immediate attention recommended.';
      case 'medium':
        return 'Some concerning patterns detected. Monitor closely and consider veterinary consultation.';
      case 'low':
        return 'Minor indicators present. Continue monitoring your pet\'s behavior.';
      default:
        return 'Unable to determine risk level. Continue regular health monitoring.';
    }
  }

  // Show veterinarian contact options
  void _showVetContactOptions() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.local_hospital, color: deepRed, size: 24),
            SizedBox(width: 8),
            Text('Find Veterinary Care'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.emergency, color: Colors.red),
              title: Text('Emergency Veterinary Clinics'),
              subtitle: Text('24/7 emergency care'),
              onTap: () {
                Navigator.pop(context);
                _showEmergencyVetInfo();
              },
            ),
            Divider(),
            ListTile(
              leading: Icon(Icons.schedule, color: Colors.blue),
              title: Text('Regular Veterinary Clinics'),
              subtitle: Text('Schedule an appointment'),
              onTap: () {
                Navigator.pop(context);
                _showRegularVetInfo();
              },
            ),
            Divider(),
            ListTile(
              leading: Icon(Icons.phone, color: Colors.green),
              title: Text('Veterinary Hotline'),
              subtitle: Text('Professional advice over phone'),
              onTap: () {
                Navigator.pop(context);
                _showVetHotlineInfo();
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _showEmergencyVetInfo() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Emergency vet feature coming soon! Call your local emergency vet clinic.'),
        backgroundColor: Colors.red,
        action: SnackBarAction(
          label: 'OK',
          textColor: Colors.white,
          onPressed: () {},
        ),
      ),
    );
  }

  void _showRegularVetInfo() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Vet appointment booking feature coming soon!'),
        backgroundColor: Colors.blue,
        action: SnackBarAction(
          label: 'OK',
          textColor: Colors.white,
          onPressed: () {},
        ),
      ),
    );
  }

  void _showVetHotlineInfo() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Vet hotline feature coming soon!'),
        backgroundColor: Colors.green,
        action: SnackBarAction(
          label: 'OK',
          textColor: Colors.white,
          onPressed: () {},
        ),
      ),
    );
  }

  // Enhanced mood and activity analytics
  Widget _buildEnhancedMoodActivityAnalytics() {
    return Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.purple.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.psychology, color: Colors.purple.shade700, size: 20),
              ),
              SizedBox(width: 12),
              Text(
                "Behavior Analytics",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  color: Colors.purple.shade700,
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
          
          // Mood Distribution
          if (_moodProb.isNotEmpty) ...[
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withOpacity(0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.mood, color: Colors.orange.shade700, size: 20),
                      SizedBox(width: 8),
                      Text(
                        "Mood Distribution",
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.orange.shade700,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _moodProb.entries.map((entry) {
                      // Case-insensitive emoji lookup
                      String emoji = '😐'; // default fallback
                      _moodEmojis.forEach((key, value) {
                        if (key.toLowerCase() == entry.key.toLowerCase()) {
                          emoji = value;
                        }
                      });
                      
                      final percentage = (entry.value * 100).round();
                      return Container(
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(emoji, style: TextStyle(fontSize: 16)),
                            SizedBox(width: 6),
                            Text(
                              '${entry.key}: $percentage%',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            SizedBox(height: 12),
          ],
          
          // Activity Distribution
          if (_activityProb.isNotEmpty) ...[
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.withOpacity(0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.pets, color: Colors.green.shade700, size: 20),
                      SizedBox(width: 8),
                      Text(
                        "Activity Distribution",
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.green.shade700,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _activityProb.entries.map((entry) {
                      // Case-insensitive emoji lookup
                      String emoji = '🚶'; // default fallback
                      _activityEmojis.forEach((key, value) {
                        if (key.toLowerCase() == entry.key.toLowerCase()) {
                          emoji = value;
                        }
                      });
                      
                      final percentage = (entry.value * 100).round();
                      return Container(
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.green.shade200),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(emoji, style: TextStyle(fontSize: 16)),
                            SizedBox(width: 6),
                            Text(
                              '${entry.key}: $percentage%',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Loading skeleton for analysis section
  Widget _buildAnalysisLoadingSkeleton() {
    return Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 20,
            width: 120,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          SizedBox(height: 12),
          Container(
            height: 16,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          SizedBox(height: 8),
          Container(
            height: 16,
            width: MediaQuery.of(context).size.width * 0.7,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }

  // Loading skeleton for chart section
  Widget _buildChartLoadingSkeleton() {
    return Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 20,
            width: 150,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          SizedBox(height: 16),
          Container(
            height: 180,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ],
      ),
    );
  }

  // Loading skeleton for distribution section
  Widget _buildDistributionLoadingSkeleton() {
    return Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 20,
            width: 140,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          SizedBox(height: 12),
          Container(
            height: 16,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }

  // Extend logging modal to support edit/update when 'existing' is provided
  void _showBehaviorModal(BuildContext context, DateTime selectedDate, {Map<String, dynamic>? existing}) {
    // Initialize form values from existing data if editing
    if (existing != null) {
      _selectedMood = existing['mood']?.toString();
      _activityLevel = existing['activity_level']?.toString();
      _sleepHours = double.tryParse(existing['sleep_hours']?.toString() ?? '');
      _notes = existing['notes']?.toString();
      _sleepController.text = _sleepHours?.toString() ?? '';
    } else {
      // Clear form for new entry
      _clearBehaviorForm();
    }
    
    final bool isEdit = existing != null && existing['id'] != null;
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      enableDrag: true,
      isDismissible: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            bool _isFormValid() {
              return _selectedMood != null && 
                     _activityLevel != null && 
                     _sleepHours != null && 
                     _sleepHours! >= 0 && 
                     _sleepHours! <= 24;
            }

            return AnimatedContainer(
              duration: Duration(milliseconds: 300),
              height: MediaQuery.of(context).size.height * 0.85,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 20,
                    spreadRadius: 5,
                    offset: Offset(0, -5),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Handle bar
                  Container(
                    margin: EdgeInsets.only(top: 12),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  
                  // Header
                  Container(
                    padding: EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [lightBlush, Colors.white],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: deepRed.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Icon(
                            isEdit ? Icons.edit : Icons.pets,
                            color: deepRed,
                            size: 24,
                          ),
                        ),
                        SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isEdit ? 'Update Behavior Log' : 'Log Pet Behavior',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: deepRed,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                DateFormat('EEEE, MMMM d, yyyy').format(selectedDate),
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.close, color: Colors.grey.shade600),
                          onPressed: () => Navigator.pop(context),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.grey.shade100,
                            shape: CircleBorder(),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Form content
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Mood Section
                          _buildFormSection(
                            title: "How is ${_selectedPet?['name'] ?? 'your pet'} feeling?",
                            icon: Icons.mood,
                            iconColor: Colors.orange,
                            child: Column(
                              children: [
                                SizedBox(height: 12),
                                GridView.builder(
                                  shrinkWrap: true,
                                  physics: NeverScrollableScrollPhysics(),
                                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 3,
                                    crossAxisSpacing: 12,
                                    mainAxisSpacing: 12,
                                    childAspectRatio: 0.8,
                                  ),
                                  itemCount: moods.length,
                                  itemBuilder: (context, index) {
                                    final mood = moods[index];
                                    final emoji = _moodEmojis[mood] ?? '•';
                                    final selected = _selectedMood == mood;
                                    
                                    return GestureDetector(
                                      onTap: () {
                                        setModalState(() => _selectedMood = mood);
                                        setState(() => _selectedMood = mood);
                                        HapticFeedback.lightImpact();
                                      },
                                      child: AnimatedContainer(
                                        duration: Duration(milliseconds: 200),
                                        padding: EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: selected 
                                            ? deepRed.withOpacity(0.15) 
                                            : Colors.grey.shade50,
                                          border: Border.all(
                                            color: selected 
                                              ? deepRed 
                                              : Colors.grey.shade300,
                                            width: selected ? 2 : 1,
                                          ),
                                          borderRadius: BorderRadius.circular(16),
                                          boxShadow: selected ? [
                                            BoxShadow(
                                              color: deepRed.withOpacity(0.3),
                                              blurRadius: 8,
                                              offset: Offset(0, 4),
                                            ),
                                          ] : null,
                                        ),
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              emoji, 
                                              style: TextStyle(fontSize: 32),
                                            ),
                                            SizedBox(height: 8),
                                            Text(
                                              mood,
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: selected 
                                                  ? FontWeight.bold 
                                                  : FontWeight.w500,
                                                color: selected 
                                                  ? deepRed 
                                                  : Colors.grey.shade700,
                                              ),
                                              textAlign: TextAlign.center,
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),

                          SizedBox(height: 24),

                          // Activity Level Section
                          _buildFormSection(
                            title: "Activity level today?",
                            icon: Icons.directions_run,
                            iconColor: Colors.green,
                            child: Column(
                              children: [
                                SizedBox(height: 12),
                                Row(
                                  children: activityLevels.map((level) {
                                    final emoji = _activityEmojis[level] ?? '•';
                                    final selected = _activityLevel == level;
                                    
                                    return Expanded(
                                      child: GestureDetector(
                                        onTap: () {
                                          setModalState(() => _activityLevel = level);
                                          setState(() => _activityLevel = level);
                                          HapticFeedback.lightImpact();
                                        },
                                        child: AnimatedContainer(
                                          duration: Duration(milliseconds: 200),
                                          margin: EdgeInsets.symmetric(horizontal: 4),
                                          padding: EdgeInsets.symmetric(vertical: 16),
                                          decoration: BoxDecoration(
                                            color: selected 
                                              ? Colors.green.withOpacity(0.15) 
                                              : Colors.grey.shade50,
                                            border: Border.all(
                                              color: selected 
                                                ? Colors.green 
                                                : Colors.grey.shade300,
                                              width: selected ? 2 : 1,
                                            ),
                                            borderRadius: BorderRadius.circular(16),
                                          ),
                                          child: Column(
                                            children: [
                                              Text(emoji, style: TextStyle(fontSize: 28)),
                                              SizedBox(height: 8),
                                              Text(
                                                level,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: selected 
                                                    ? FontWeight.bold 
                                                    : FontWeight.w500,
                                                  color: selected 
                                                    ? Colors.green 
                                                    : Colors.grey.shade700,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ],
                            ),
                          ),

                          SizedBox(height: 24),

                          // Sleep Hours Section
                          _buildFormSection(
                            title: "Sleep hours",
                            icon: Icons.bedtime,
                            iconColor: Colors.blue,
                            child: Column(
                              children: [
                                SizedBox(height: 12),
                                Container(
                                  padding: EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.withOpacity(0.05),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: Colors.blue.withOpacity(0.2),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: TextFormField(
                                          controller: _sleepController,
                                          keyboardType: TextInputType.numberWithOptions(decimal: true),
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          decoration: InputDecoration(
                                            border: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(12),
                                              borderSide: BorderSide.none,
                                            ),
                                            filled: true,
                                            fillColor: Colors.white,
                                            hintText: "0.0",
                                            hintStyle: TextStyle(color: Colors.grey.shade400),
                                            contentPadding: EdgeInsets.symmetric(
                                              horizontal: 16, 
                                              vertical: 16,
                                            ),
                                            suffixText: "hours",
                                            suffixStyle: TextStyle(
                                              color: Colors.grey.shade600,
                                              fontSize: 14,
                                            ),
                                          ),
                                          onChanged: (value) {
                                            final parsed = double.tryParse(value);
                                            setModalState(() {
                                              if (parsed == null || parsed < 0) {
                                                _sleepHours = null;
                                              } else if (parsed > 24) {
                                                _sleepHours = 24;
                                                _sleepController.text = "24";
                                                _sleepController.selection = TextSelection.fromPosition(
                                                  TextPosition(offset: _sleepController.text.length)
                                                );
                                              } else {
                                                _sleepHours = parsed;
                                              }
                                            });
                                            setState(() {
                                              if (parsed == null || parsed < 0) {
                                                _sleepHours = null;
                                              } else if (parsed > 24) {
                                                _sleepHours = 24;
                                              } else {
                                                _sleepHours = parsed;
                                              }
                                            });
                                          },
                                        ),
                                      ),
                                      SizedBox(width: 12),
                                      Column(
                                        children: [
                                          _buildSleepButton(
                                            icon: Icons.add,
                                            onPressed: () {
                                              final current = _sleepHours ?? 
                                                double.tryParse(_sleepController.text) ?? 0.0;
                                              final next = (current + 0.5).clamp(0.0, 24.0);
                                              setModalState(() {
                                                _sleepHours = double.parse(next.toStringAsFixed(1));
                                                _sleepController.text = _sleepHours.toString();
                                              });
                                              setState(() {
                                                _sleepHours = double.parse(next.toStringAsFixed(1));
                                                _sleepController.text = _sleepHours.toString();
                                              });
                                              HapticFeedback.lightImpact();
                                            },
                                          ),
                                          SizedBox(height: 8),
                                          _buildSleepButton(
                                            icon: Icons.remove,
                                            onPressed: () {
                                              final current = _sleepHours ?? 
                                                double.tryParse(_sleepController.text) ?? 0.0;
                                              final next = (current - 0.5).clamp(0.0, 24.0);
                                              setModalState(() {
                                                _sleepHours = double.parse(next.toStringAsFixed(1));
                                                _sleepController.text = _sleepHours.toString();
                                              });
                                              setState(() {
                                                _sleepHours = double.parse(next.toStringAsFixed(1));
                                                _sleepController.text = _sleepHours.toString();
                                              });
                                              HapticFeedback.lightImpact();
                                            },
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                if (_sleepHours != null) ...[
                                  SizedBox(height: 12),
                                  Container(
                                    padding: EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.blue.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(Icons.info_outline, color: Colors.blue, size: 16),
                                        SizedBox(width: 8),
                                        Text(
                                          _getSleepFeedback(_sleepHours!),
                                          style: TextStyle(
                                            color: Colors.blue.shade700,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),

                          SizedBox(height: 24),

                          // Notes Section
                          _buildFormSection(
                            title: "Additional notes (optional)",
                            icon: Icons.note_alt,
                            iconColor: Colors.purple,
                            child: Column(
                              children: [
                                SizedBox(height: 12),
                                TextFormField(
                                  initialValue: _notes,
                                  maxLines: 4,
                                  style: TextStyle(fontSize: 16),
                                  decoration: InputDecoration(
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(color: Colors.grey.shade300),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(color: deepRed, width: 2),
                                    ),
                                    filled: true,
                                    fillColor: Colors.grey.shade50,
                                    hintText: "Any observations, behaviors, or concerns...",
                                    hintStyle: TextStyle(color: Colors.grey.shade400),
                                    contentPadding: EdgeInsets.all(16),
                                  ),
                                  onChanged: (value) {
                                    setModalState(() => _notes = value);
                                    setState(() => _notes = value);
                                  },
                                ),
                              ],
                            ),
                          ),

                          SizedBox(height: 32),
                        ],
                      ),
                    ),
                  ),

                  // Bottom Action Button
                  Container(
                    padding: EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 10,
                          offset: Offset(0, -5),
                        ),
                      ],
                    ),
                    child: SafeArea(
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isFormValid() ? deepRed : Colors.grey.shade300,
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            elevation: _isFormValid() ? 4 : 0,
                          ),
                          icon: Icon(
                            isEdit ? Icons.check : Icons.save,
                            size: 20,
                          ),
                          label: Text(
                            isEdit ? "Update Behavior Log" : "Save Behavior Log",
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          onPressed: !_isFormValid() ? null : () async {
                            try {
                              // Show loading state
                              setModalState(() {});
                              
                              final payload = {
                                'pet_id': _selectedPet!['id'],
                                'user_id': user?.id ?? '',
                                'log_date': DateFormat('yyyy-MM-dd').format(selectedDate),
                                'notes': _notes,
                                'mood': _selectedMood,
                                'sleep_hours': _sleepHours,
                                'activity_level': _activityLevel,
                              };
                              
                              if (isEdit) {
                                await Supabase.instance.client
                                    .from('behavior_logs')
                                    .update(payload)
                                    .eq('id', existing['id']);
                              } else {
                                await Supabase.instance.client
                                    .from('behavior_logs')
                                    .insert(payload);
                              }

                              // Close the modal
                              if (mounted) Navigator.of(context).pop();

                              // Refresh data
                              await _fetchBehaviorDates();
                              await _fetchAnalyzeFromBackend();
                              await _fetchLatestMood(); // Refresh latest mood for health status

                              // Show success feedback
                              if (mounted) {
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(
                                    content: Row(
                                      children: [
                                        Icon(Icons.check_circle, color: Colors.white),
                                        SizedBox(width: 8),
                                        Text(isEdit 
                                          ? 'Behavior log updated successfully!' 
                                          : 'Behavior logged and analyzed!'),
                                      ],
                                    ),
                                    backgroundColor: Colors.green,
                                    behavior: SnackBarBehavior.floating,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                );
                              }
                            } catch (e) {
                              if (mounted) {
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(
                                    content: Row(
                                      children: [
                                        Icon(Icons.error, color: Colors.white),
                                        SizedBox(width: 8),
                                        Expanded(
                                          child: Text('Failed to save: ${e.toString()}'),
                                        ),
                                      ],
                                    ),
                                    backgroundColor: Colors.red,
                                    behavior: SnackBarBehavior.floating,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // Helper widget for form sections
  Widget _buildFormSection({
    required String title,
    required IconData icon,
    required Color iconColor,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: iconColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: iconColor, size: 20),
                ),
                SizedBox(width: 12),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade800,
                  ),
                ),
              ],
            ),
            child,
          ],
        ),
      ),
    );
  }

  // Helper widget for sleep adjustment buttons
  Widget _buildSleepButton({
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.withOpacity(0.3)),
      ),
      child: IconButton(
        icon: Icon(icon, color: Colors.blue, size: 20),
        onPressed: onPressed,
        padding: EdgeInsets.all(8),
        constraints: BoxConstraints(minWidth: 40, minHeight: 40),
      ),
    );
  }

  // Helper method to provide sleep feedback
  String _getSleepFeedback(double hours) {
    if (hours < 6) {
      return "This seems low for most pets. Consider monitoring.";
    } else if (hours >= 6 && hours <= 14) {
      return "Normal sleep range for most pets.";
    } else if (hours > 14 && hours <= 18) {
      return "A bit high but normal for some pets.";
    } else {
      return "This seems quite high. Monitor for any changes.";
    }
  }

  // Enhanced Pet Profile Header
  Widget _buildPetProfileHeader() {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Card(
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: [deepRed.withOpacity(0.8), coral],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          padding: EdgeInsets.all(20),
          child: Column(
            children: [
              // Centered, larger profile picture
              CircleAvatar(
                radius: 60,
                backgroundColor: Colors.white,
                backgroundImage: _selectedPet!['profile_picture'] != null &&
                        _selectedPet!['profile_picture'].toString().isNotEmpty
                    ? NetworkImage(_selectedPet!['profile_picture'])
                    : null,
                child: _selectedPet!['profile_picture'] == null ||
                        _selectedPet!['profile_picture'].toString().isEmpty
                    ? Icon(Icons.pets, size: 60, color: deepRed)
                    : null,
              ),
              SizedBox(height: 16),
              // Pet name centered below picture
              Text(
                _selectedPet!['name'] ?? 'Unnamed',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 12),
              // Breed and age in a single row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Expanded(
                    child: _buildPetInfoCard(
                      icon: Icons.pets,
                      title: 'Breed',
                      value: _selectedPet!['breed'] ?? 'Unknown',
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: _buildPetInfoCard(
                      icon: Icons.calendar_today,
                      title: 'Age',
                      value: _getFormattedAge(_selectedPet!),
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Enhanced Pet Stats Card
  Widget _buildPetStatsCard() {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              colors: [Colors.white, lightBlush.withOpacity(0.3)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          padding: EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Health & Status',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: deepRed,
                ),
              ),
              SizedBox(height: 8),
              // Single row with all status items
              Row(
                children: [
                  Expanded(
                    child: _buildCompactStatCard(
                      icon: Icons.favorite,
                      title: 'Health',
                      value: _isUnhealthy ? 'Attention' : 'Good',
                      color: _isUnhealthy ? deepRed : Colors.green,
                    ),
                  ),
                  SizedBox(width: 6),
                  Expanded(
                    child: _buildCompactStatCard(
                      icon: Icons.monitor_weight,
                      title: 'Weight',
                      value: '${_selectedPet!['weight']} kg',
                      color: coral,
                    ),
                  ),
                  SizedBox(width: 6),
                  Expanded(
                    child: _buildCompactStatCard(
                      icon: Icons.security,
                      title: 'Status',
                      value: _selectedPet!['is_missing'] == true ? 'Missing' : 'Safe',
                      color: _selectedPet!['is_missing'] == true ? deepRed : Colors.green,
                    ),
                  ),
                  SizedBox(width: 6),
                  Expanded(
                    child: _buildCompactStatCard(
                      icon: Icons.mood,
                      title: 'Mood',
                      value: _latestMood != null ? 
                        '${_moodEmojis[_latestMood!] ?? ''} $_latestMood' : 'Unknown',
                      color: _latestMood != null ? 
                        (_latestMood == 'Happy' ? Colors.green :
                         _latestMood == 'Anxious' ? Colors.orange :
                         _latestMood == 'Aggressive' ? Colors.red :
                         _latestMood == 'Calm' ? Colors.blue :
                         _latestMood == 'Lethargic' ? Colors.grey :
                         Colors.orange) : Colors.grey,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Helper method for info cards
  Widget _buildPetInfoCard({
    required IconData icon,
    required String title,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3), width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              color: color.withOpacity(0.8),
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
          ),
          SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ],
      ),
    );
  }

  // Helper method to build pet avatar
  Widget _buildPetAvatar(Map<String, dynamic> pet, bool isSelected) {
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isSelected
              ? [coral.withOpacity(0.8), peach.withOpacity(0.8)]
              : [Colors.grey.shade300, Colors.grey.shade400],
        ),
      ),
      child: Center(
        child: Text(
          (pet['name'] ?? 'U')[0].toUpperCase(),
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
      ),
    );
  }

  // Helper method to get health status color
  Color _getHealthStatusColor(String health) {
    switch (health.toLowerCase()) {
      case 'excellent':
        return Colors.green;
      case 'good':
        return Colors.blue;
      case 'fair':
        return Colors.orange;
      case 'poor':
        return Colors.red;
      default:
        return Colors.blue;
    }
  }

  // Helper method to get pet type icon
  IconData _getPetTypeIcon(String type) {
    switch (type.toLowerCase()) {
      case 'dog':
        return Icons.pets;
      case 'cat':
        return Icons.pets;
      case 'bird':
        return Icons.flutter_dash;
      case 'rabbit':
        return Icons.cruelty_free;
      default:
        return Icons.pets;
    }
  }

  // Helper method for stat cards
  Widget _buildPetStatCard({
    required IconData icon,
    required String title,
    required String value,
    required Color color,
    required Color bgColor,
  }) {
    return Container(
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3), width: 1),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          SizedBox(height: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              color: color.withOpacity(0.7),
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              color: color,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // Helper method for compact stat cards (minimized version)
  Widget _buildCompactStatCard({
    required IconData icon,
    required String title,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3), width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          SizedBox(height: 2),
          Text(
            title,
            style: TextStyle(
              fontSize: 9,
              color: color.withOpacity(0.7),
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 10,
              color: color,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
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