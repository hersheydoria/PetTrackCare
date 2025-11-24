import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart'; // For date formatting
import 'package:flutter/foundation.dart'; // For kDebugMode
import 'notification_screen.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:table_calendar/table_calendar.dart';
import 'package:qr_flutter/qr_flutter.dart' as qr_flutter;
import 'package:flutter/services.dart'; // for Clipboard and HapticFeedback
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/notification_service.dart';
import '../services/missing_pet_alert_service.dart';
import '../services/auto_migration_service.dart';

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
  RealtimeChannel? _selectedPetChannel; // Realtime listener for selected pet updates
  RealtimeChannel? _locationHistoryChannel; // Realtime listener for location history updates
  
  // Auto-migration service
  final AutoMigrationService _autoMigrationService = AutoMigrationService();
  
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
  
  // Request tracking to prevent stale responses from overwriting current pet's analysis
  String? _currentAnalysisRequestId;

  String backendUrl = "https://pettrackcare.onrender.com/analyze";
  Map<String, double> _moodProb = {};
  Map<String, double> _activityProb = {};

  // Behavior tab state
  String? _selectedBehavior;
  DateTime? _selectedDate = DateTime.now();
  String? _prediction;
  String? _recommendation;
  List<Widget> _healthInsights = []; // Health insights from latest log

  // 🔹 Moved from local scope to state variables
  String? _activityLevel;

  // New health tracking fields
  String? _foodIntake; // "Not Eating", "Eating Less", "Normal", "Eating More"
  String? _waterIntake; // "Not Drinking", "Drinking Less", "Normal", "Drinking More"
  String? _bathroomHabits; // "Normal", "Diarrhea", "Constipation", "Frequent Urination"
  List<String> _selectedSymptoms = []; // Multiple symptoms
  

  // illness risk returned by backend (high/low/null)
  String? _illnessRisk;
  bool _isUnhealthy = false;
  
  // Track health status for each pet (petId -> isUnhealthy)
  Map<String, bool> _petHealthStatus = {};
  
  // Backend messaging about analysis quality and data sufficiency
  Map<String, dynamic>? _dataNotice; // tells user about log count sufficiency
  Map<String, dynamic>? _healthGuidance; // evidence-based health guidance based on detected symptoms
  Map<String, dynamic>? _illnessRiskNotice; // illness risk status (low/medium/high)

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
  String? _lastMissingPostId;

  // Food Intake & Weight-Related Behavior
  final List<String> foodIntakeOptions = [
    "Not eating / Loss of appetite",
    "Eating less than usual",
    "Normal eating",
    "Eating more than usual",
    "Sudden weight loss",
    "Sudden weight gain"
  ];

  // Water Intake (Reflects dehydration risks & diseases like diabetes/kidney issues)
  final List<String> waterIntakeOptions = [
    "Not drinking",
    "Drinking less than usual",
    "Normal drinking",
    "Excessive drinking (increased thirst)"
  ];

  // Bathroom Habits (Expanded to include urgent medical indicators)
  final List<String> bathroomOptions = [
    "Normal urination/defecation",
    "Diarrhea",
    "Constipation",
    "Frequent urination",
    "Straining to urinate",
    "Blood in urine",
    "House soiling / accidents"
  ];



  // Clinical Signs (Physical Symptoms) - Expanded set directly based on health indicators
  final List<String> commonSymptoms = [
    "Vomiting",
    "Persistent vomiting",
    "Coughing",
    "Sneezing",
    "Wheezing / difficulty breathing",
    "Excessive panting",
    "Excessive scratching",
    "Excessive grooming / licking",
    "Hair loss / bald spots",
    "Skin redness or irritation",
    "Limping",
    "Difficulty standing or moving",
    "Bloating / bloated stomach",
    "Excessive drooling",
    "Bad breath",
    "Eye or nose discharge",
    "Trembling / shaking",
    "None of the Above"
  ];

  // Activity Level & Energy (Incorporates fatigue and restlessness patterns tied to diseases)
  final List<String> activityLevels = [
    "High activity",
    "Normal activity",
    "Low activity / lethargy",
    "Restlessness (especially at night)",
    "Sudden weakness / collapse"
  ];

  // Add these variables
  CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  // map of date -> list of event markers (used by TableCalendar)
  Map<DateTime, List<String>> _events = {};

  // emoji mappings for activity
  final Map<String, String> _activityEmojis = {
    'High activity': '🐕',
    'Normal activity': '🐾',
    'Low activity / lethargy': '🐶',
    'Restlessness (especially at night)': '😰',
    'Sudden weakness / collapse': '⚠️',
    // Legacy mappings for backward compatibility
    'High': '🐕',
    'Medium': '🐾',
    'Low': '🐶',
  };

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
  
  // Helper method to clear location cache (used after migration)
  void _clearLocationCache() {
    if (mounted) {
      setState(() {
        _latestDeviceLocation = null;
        _latestDeviceTimestamp = null;
        _latestDeviceId = null;
        _locationHistory = [];
        _currentMapLocation = null;
        _currentMapLabel = null;
        _currentMapSub = null;
      });
    }
  }

  // Background data fetching with caching
  Future<void> _fetchPetDataInBackground(String petId) async {
    try {
      // OPTIMIZATION: Run ALL independent fetches in parallel instead of sequential
      // This massively improves load times as they all run simultaneously
      await Future.wait([
        _fetchBehaviorDates(),
        _fetchLatestLocationForPet(),
        _fetchAnalyzeFromBackend(),
        _fetchLatestHealthInsights(), // All run in parallel now
      ], eagerError: false); // Continue even if one fails

      // Cache the results
      final dataToCache = {
        'events': _events,
        'prediction': _prediction,
        'recommendation': _recommendation,
        'moodProb': _moodProb,
        'activityProb': _activityProb,
        'illnessRisk': _illnessRisk,
        'isUnhealthy': _isUnhealthy,
        'timestamp': DateTime.now(),
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
      // Handle errors gracefully - still update UI even if some fetches fail
      print('Error in _fetchPetDataInBackground: $e');
      if (mounted) {
        setState(() {
          _loadingBehaviorData = false;
          _loadingAnalysisData = false;
          _loadingLocationData = false;
        });
      }
    }
  }

  // Helper method to save selected pet ID to persistent storage
  Future<void> _saveSelectedPetId(String petId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selected_pet_id', petId);
    } catch (e) {
      // Silent fail - not critical if we can't save preference
    }
  }

  // Helper method to restore previously selected pet ID from persistent storage
  Future<String?> _getLastSelectedPetId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('selected_pet_id');
    } catch (e) {
      return null;
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
        
        // Load health status for all pets from database
        final Map<String, bool> petHealthMap = {};
        for (final pet in list) {
          final petHealth = pet['health']?.toString().toLowerCase() ?? 'good';
          petHealthMap[pet['id']] = (petHealth == 'bad');
        }
        
        // Try to restore previously selected pet
        final lastSelectedPetId = await _getLastSelectedPetId();
        
        if (widget.initialPet != null) {
          // Prefer widget.initialPet if provided (match by id)
          final initId = widget.initialPet!['id'];
          try {
            selected = list.firstWhere((p) => p['id'] == initId, orElse: () => widget.initialPet!);
          } catch (_) {
            selected = widget.initialPet;
          }
        } else if (lastSelectedPetId != null) {
          // Try to restore the last selected pet
          try {
            selected = list.firstWhere((p) => p['id'] == lastSelectedPetId, orElse: () => list.first);
          } catch (_) {
            selected = list.first;
          }
        } else {
          // Fallback to first pet
          selected = list.first;
        }
        
        setState(() {
          _pets = list;
          _selectedPet = selected;
          _petHealthStatus = petHealthMap;  // Load health status for all pets
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
        
        // Setup realtime listener for pet updates (e.g., is_missing status changes)
        _setupSelectedPetListener();
        
        // Setup realtime listener for location history updates
        _setupLocationHistoryListener();
        
        // Save the selected pet ID for future sessions
        if (selected != null) {
          _saveSelectedPetId(selected['id']);
        }
        
        // Trigger additional fetches in background so UI can render immediately.
        // We intentionally do NOT await these so they don't keep the loader visible
        _fetchBehaviorDates();
        // Fetch analysis first, then health insights (insights depend on _isUnhealthy being set)
        _fetchAnalyzeFromBackend().then((_) {
          _fetchLatestHealthInsights(); // <-- fetch health insights for last 7 days (after analysis)
        });
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

  // Removed: _fetchLatestAnalysis() function - predictions table is deprecated
  // Analysis is now fetched directly from the /analyze endpoint via _fetchHealthAnalysis()
  // The app now calls _fetchHealthAnalysis() which gets fresh analysis from /analyze endpoint

  // Fetch health insights from backend analysis - only last 7 days to prevent confusion about timeframe
  Future<void> _fetchLatestHealthInsights() async {
    if (_selectedPet == null) return;
    final petId = _selectedPet!['id'];
    
    try {
      // OPTIMIZATION: Only fetch last 30 days of logs and limit to 100 records
      final thirtyDaysAgo = DateTime.now().subtract(Duration(days: 30)).toIso8601String();
      final response = await Supabase.instance.client
          .from('behavior_logs')
          .select()
          .eq('pet_id', petId)
          .gte('log_date', thirtyDaysAgo)
          .order('log_date', ascending: false)
          .limit(100); // OPTIMIZATION: Limit to 100 records max

      final data = response as List?;
      print('DEBUG: _fetchLatestHealthInsights - Got ${data?.length ?? 0} behavior logs for pet $petId');
      
      // Determine if backend flagged a persistent illness
      final bool persistentFromNotice = _illnessRiskNotice?['is_persistent'] == true;
      final bool persistentFromGuidance = _healthGuidance?['is_persistent_illness'] == true;
      final bool hasPersistentIllness = persistentFromNotice || persistentFromGuidance;
      final int? persistenceDays = (_illnessRiskNotice?['persistence_days'] as num?)?.toInt() ??
          (_healthGuidance?['illness_duration_days'] as num?)?.toInt();

      // Generate insights based on backend's trained model prediction (_isUnhealthy flag)
      List<Widget> insights = [];
      
      if (data != null && data.isNotEmpty) {
        // Filter logs to last 7 days only
        final sevenDaysAgo = DateTime.now().subtract(Duration(days: 7));
        final logsInLast7Days = data.where((log) {
          try {
            final logDate = DateTime.parse(log['log_date'].toString());
            return logDate.isAfter(sevenDaysAgo);
          } catch (e) {
            print('DEBUG: Error parsing log date: ${log['log_date']} - $e');
            return false;
          }
        }).toList();
        
        print('DEBUG: Filtered to ${logsInLast7Days.length} logs in last 7 days (total: ${data.length})');
        if (logsInLast7Days.isEmpty && !hasPersistentIllness) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('No behavior logs recorded in the last 7 days. Add new entries to keep insights current.'),
              duration: Duration(seconds: 4),
            ),
          );
        }

        final List<dynamic> logsForAnalysis = (hasPersistentIllness && data.isNotEmpty)
            ? data
            : logsInLast7Days;
        final String analysisWindowLabel = hasPersistentIllness
            ? 'persistent window (${persistenceDays != null ? '$persistenceDays days' : 'full history'})'
            : 'last 7 days';
        print('DEBUG: Using ${logsForAnalysis.length} logs for health insights ($analysisWindowLabel)');

        if (logsForAnalysis.isEmpty) {
          final notice = hasPersistentIllness
              ? 'Illness marked persistent but no logs exist in the analyzed window. Add new logs for updated insights.'
              : 'No logs available for analysis. Log new behavior entries to generate insights.';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(notice),
              duration: Duration(seconds: 4),
            ),
          );
        } else if (_isUnhealthy) {
          print('DEBUG: Backend detected unhealthy status (risk: $_illnessRisk), analyzing specific issues...');
          
          // Extract issues from the actual logs that triggered the unhealthy flag
          List<String> problems = [];
          
          for (final log in logsForAnalysis) {
            final foodIntake = log['food_intake']?.toString().toLowerCase() ?? '';
            final waterIntake = log['water_intake']?.toString().toLowerCase() ?? '';
            final bathroomHabits = log['bathroom_habits']?.toString().toLowerCase() ?? '';
            
            // Parse symptoms - handle both List and String formats
            List<String> symptoms = [];
            final symptomsData = log['symptoms'];
            if (symptomsData != null) {
              try {
                if (symptomsData is List) {
                  symptoms = List<String>.from(symptomsData);
                } else if (symptomsData is String) {
                  // Try to parse as JSON array
                  try {
                    final decoded = json.decode(symptomsData);
                    if (decoded is List) {
                      symptoms = List<String>.from(decoded);
                    } else {
                      symptoms = [];
                    }
                  } catch (_) {
                    symptoms = [];
                  }
                }
              } catch (e) {
                print('DEBUG: Error parsing symptoms: $e');
                symptoms = [];
              }
            }
            
            // Filter out "None of the Above" - it's not a real symptom
            symptoms = symptoms
                .where((s) => s.toLowerCase() != "none of the above" && s.trim().isNotEmpty)
                .toList();
            
            final mood = log['mood']?.toString().toLowerCase() ?? '';
            final activity = log['activity_level']?.toString().toLowerCase() ?? '';
            
            if (foodIntake.contains('not eating') || foodIntake.contains('eating less')) {
              problems.add('Reduced Food Intake');
            }
            if (waterIntake.contains('not drinking') || waterIntake.contains('drinking less')) {
              problems.add('Low Water Intake');
            }
            if (waterIntake.contains('drinking more')) {
              problems.add('Excessive Thirst');
            }
            if (bathroomHabits.contains('diarrhea') || bathroomHabits.contains('constipation')) {
              problems.add('Digestive Issues');
            }
            if (mood.contains('lethargic') || mood.contains('aggressive') || mood.contains('anxious')) {
              problems.add('Mood Changes');
            }
            if (activity.contains('low')) {
              problems.add('Low Activity');
            }
            if (symptoms.isNotEmpty) {
              problems.add('Reported Clinical Signs');
            }
          }
          
          // Remove duplicates
          final uniqueProblems = problems.toSet().toList();
          print('DEBUG: Identified ${uniqueProblems.length} specific health issues: $uniqueProblems');
          
          // Generate insight cards for each problem
          if (uniqueProblems.contains('Reduced Food Intake')) {
            insights.add(_buildInsightItem(
              'Reduced Appetite',
              'Pet showing reduced food intake. Monitor feeding behavior.',
              Icons.warning,
              Colors.red,
            ));
          }
          if (uniqueProblems.contains('Low Water Intake')) {
            insights.add(_buildInsightItem(
              'Low Hydration',
              'Pet drinking less water than normal. Ensure water access.',
              Icons.warning,
              Colors.red,
            ));
          }
          if (uniqueProblems.contains('Excessive Thirst')) {
            insights.add(_buildInsightItem(
              'Excessive Thirst',
              'Pet drinking more than usual. May indicate health concerns.',
              Icons.info,
              Colors.red,
            ));
          }
          if (uniqueProblems.contains('Digestive Issues')) {
            insights.add(_buildInsightItem(
              'Digestive Problems',
              'Bathroom habit changes detected. Monitor for patterns.',
              Icons.warning,
              Colors.red,
            ));
          }
          if (uniqueProblems.contains('Mood Changes')) {
            insights.add(_buildInsightItem(
              'Behavioral Changes',
              'Mood changes detected. Provide supportive environment.',
              Icons.sentiment_very_dissatisfied,
              Colors.orange,
            ));
          }
          if (uniqueProblems.contains('Low Activity')) {
            insights.add(_buildInsightItem(
              'Low Activity Level',
              'Pet showing reduced activity. Encourage gentle movement.',
              Icons.trending_down,
              Colors.orange,
            ));
          }
          if (uniqueProblems.contains('Reported Clinical Signs')) {
            insights.add(_buildInsightItem(
              'Clinical Signs Present',
              'Pet showing reported clinical signs. Monitor and document.',
              Icons.medical_services,
              Colors.red,
            ));
          }
        }
      }
      else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No behavior logs found in the past 30 days. Add new logs to receive health insights.'),
            duration: Duration(seconds: 4),
          ),
        );
      }
      
      print('DEBUG: Generated ${insights.length} insights based on backend analysis (unhealthy: $_isUnhealthy)');
      setState(() {
        _healthInsights = insights;
      });
    } catch (e) {
      print('Error fetching latest health insights: $e');
      setState(() {
        _healthInsights = [];
      });
    }
  }

  // fetch behavior log dates for the selected pet and populate _events with a marker
  Future<void> _fetchBehaviorDates() async {
    if (_selectedPet == null) return;
    try {
      final petId = _selectedPet!['id'];
      // OPTIMIZATION: Only fetch last 120 days for calendar display instead of all logs
      final cutoffDate = DateTime.now().subtract(Duration(days: 120)).toIso8601String();
      final response = await Supabase.instance.client
          .from('behavior_logs')
          .select('log_date')
          .eq('pet_id', petId)
          .gte('log_date', cutoffDate) // Only fetch last 120 days
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
      if (mounted) {
        setState(() {
          _events = map;
        });
      }
    } catch (e) {
      // ignore / optionally log
    }
  }

  // Call backend /analyze to get illness risk and analysis summary.
  Future<void> _fetchAnalyzeFromBackend() async {
    if (_selectedPet == null) return;
    
    final petId = _selectedPet!['id'];
    // Generate unique request ID for this pet's analysis fetch
    final requestId = '${petId}_${DateTime.now().millisecondsSinceEpoch}';
    _currentAnalysisRequestId = requestId;
    
    final requestBody = {'pet_id': petId};

    try {
      final resp = await http.post(
        Uri.parse(backendUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestBody),
      ).timeout(
        Duration(seconds: 8), // OPTIMIZATION: Reduced timeout from 10s to 8s for faster feedback
        onTimeout: () => throw TimeoutException('Analysis request timed out'),
      );
      
      // Verify this response is still relevant (pet hasn't changed or another request hasn't been sent)
      if (_currentAnalysisRequestId != requestId) {
        // Stale response - pet changed or new request was made
        return;
      }
      
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        
        // Double-check pet hasn't changed before updating state
        if (_selectedPet == null || _selectedPet!['id'] != petId) {
          return;
        }
        
        // Verify response is for the correct pet
        if (body['pet_id'] != null && body['pet_id'] != petId) {
          print('WARNING: Backend returned analysis for wrong pet! Expected $petId, got ${body['pet_id']}');
          return;
        }
        
        setState(() {
          _prediction = (body['trend'] ?? body['prediction_text'] ?? body['prediction'])?.toString();
          _recommendation = (body['recommendation'] ?? body['suggestions'])?.toString();
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
          
          // Store health status for this pet
          if (_selectedPet != null) {
            _petHealthStatus[_selectedPet!['id']] = _isUnhealthy;
          }

          // Parse data_notice and model_notice from backend response
          _dataNotice = body['data_notice'] as Map<String, dynamic>?;
          _healthGuidance = body['health_guidance'] as Map<String, dynamic>?;
          _illnessRiskNotice = body['illness_risk_notice'] as Map<String, dynamic>?;
        });
        
        // Persist health status to database after UI update
        final healthStatus = _isUnhealthy ? 'Bad' : 'Good';
        try {
          await Supabase.instance.client
              .from('pets')
              .update({'health': healthStatus})
              .eq('id', petId);
          print('DEBUG: Updated pet health status to: $healthStatus');
        } catch (e) {
          print('Error updating pet health status: $e');
        }
      } else {
        // non-200 response: ignore for now
        print('Analysis request returned status ${resp.statusCode}');
      }
    } on TimeoutException catch (e) {
      print('Analysis request timeout: $e');
      // Silently fail - don't update UI
    } catch (e) {
      // ignore network errors silently or log
      print('Analysis fetch error: $e');
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
      // OPTIMIZATION: Skip location fetch if no device was previously mapped and still isn't
      if (_latestDeviceId == null && _latestDeviceLocation == null) {
        // Quick check to see if device was recently added
        final devResp = await Supabase.instance.client
            .from('device_pet_map')
            .select('device_id')
            .eq('pet_id', petId)
            .limit(1);
        final devList = devResp as List? ?? [];
        final deviceId = devList.isNotEmpty ? devList.first['device_id']?.toString() : null;
        if (deviceId == null || deviceId.isEmpty) {
          // No device mapped for this pet
          return;
        }
      }
      
      // 1) find device_id in device_pet_map
      final devResp = await Supabase.instance.client
          .from('device_pet_map')
          .select('device_id')
          .eq('pet_id', petId)
          .limit(1);
      final devList = devResp as List? ?? [];
      final deviceId = devList.isNotEmpty ? devList.first['device_id']?.toString() : null;
      if (deviceId == null || deviceId.isEmpty) {
        if (mounted) {
          setState(() {
            _latestDeviceLocation = null;
            _latestDeviceTimestamp = null;
            _latestDeviceId = null;
            _locationHistory = [];
          });
        }
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
        
        // Fetch location history first to get address
        await _fetchLocationHistoryForDevice(deviceId, petId: petId);
        
        if (mounted) {
          setState(() {
            _latestDeviceId = deviceId;
            _latestDeviceTimestamp = ts;
            _latestDeviceLocation = (lat != null && lng != null) ? LatLng(lat, lng) : null;
            
            // Automatically set the map to show the latest location
            // Always reset to latest location when fetching (e.g., when switching pets or refreshing)
            if (_latestDeviceLocation != null) {
              _currentMapLocation = _latestDeviceLocation;
              // Get address from location history if available
              if (_locationHistory.isNotEmpty) {
                final latestHistory = _locationHistory.first;
                final address = latestHistory['address']?.toString();
                if (address != null && address.isNotEmpty) {
                  _currentMapLabel = address;
                } else {
                  _currentMapLabel = 'Live GPS Location';
                }
                _currentMapSub = ts != null ? DateFormat('MMM d, yyyy • h:mm a').format(ts) : 'Latest location';
              } else {
                _currentMapLabel = 'Live GPS Location';
                _currentMapSub = ts != null ? DateFormat('MMM d, yyyy • h:mm a').format(ts) : 'Latest location';
              }
            }
          });
        }
  
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

   // Fetch recent location_history rows (limit 8) for device and reverse-geocode addresses.
  Future<void> _fetchLocationHistoryForDevice(String deviceId, {required String petId, int limit = 8}) async {
    try {
      final resp = await Supabase.instance.client
          .from('location_history')
          .select('id,latitude,longitude,timestamp,device_mac,pet_id,firebase_entry_id') // Include firebase_entry_id to check if migrated from Firebase
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
          final firebaseEntryId = row['firebase_entry_id'] as String?;
          DateTime? ts;
          final rawTs = row['timestamp'];
          if (rawTs is String) {
            ts = DateTime.tryParse(rawTs);
            // If timestamp includes timezone info (e.g., "2025-11-18T14:30:00+08:00"), parse it correctly
            if (ts != null && rawTs.contains('+')) {
              // Already timezone-aware from database, use as-is
              ts = DateTime.tryParse(rawTs);
            }
          } else if (rawTs is DateTime) {
            ts = rawTs;
          }
          
          // Note: Supabase already stores the correct local time with timezone info
          // No need to add any timezone offset
          
          records.add({
            'latitude': lat,
            'longitude': lng,
            'timestamp': ts,
            'device_mac': row['device_mac'],
            'firebase_entry_id': firebaseEntryId,
            'address': null, // Will be resolved asynchronously
          });
        } catch (e) {
          // skip malformed row
          if (kDebugMode) print('Error parsing location record: $e');
        }
      }
      
      if (mounted) {
        setState(() {
          _locationHistory = records;
        });
      }
      
      // Resolve addresses in parallel for all locations after a short delay to allow UI to render first
      if (records.isNotEmpty) {
        Future.delayed(Duration(milliseconds: 100), () {
          if (mounted) {
            _resolveAddressesForLocationHistory();
          }
        });
      }
    } catch (e) {
      if (kDebugMode) print('Error fetching location history: $e');
      if (mounted) {
        setState(() {
          _locationHistory = [];
        });
      }
    }
  }

  // Resolve addresses for all location history items with rate limiting
  Future<void> _resolveAddressesForLocationHistory() async {
    if (_locationHistory.isEmpty) return;
    
    if (kDebugMode) print('🔄 Starting address resolution for ${_locationHistory.length} locations...');
    
    try {
      bool hasUpdates = false;
      int resolvedCount = 0;
      
      // Process addresses sequentially with a small delay between requests to avoid overwhelming the API
      for (int i = 0; i < _locationHistory.length; i++) {
        final record = _locationHistory[i];
        final lat = record['latitude'] as double?;
        final lng = record['longitude'] as double?;
        final existingAddress = record['address'] as String?;
        
        // Only resolve if we don't have an address yet
        if (lat != null && lng != null && (existingAddress == null || existingAddress.isEmpty)) {
          try {
            final address = await _reverseGeocode(lat, lng);
            if (address != null && address.isNotEmpty && i < _locationHistory.length) {
              _locationHistory[i]['address'] = address;
              hasUpdates = true;
              resolvedCount++;
              if (kDebugMode) print('✅ [$resolvedCount] Resolved address for location $i: $address');
            } else if (kDebugMode) {
              print('⚠️  Failed to resolve address for location $i');
            }
            
            // Add a small delay between requests to respect API rate limits (avoid 429 Too Many Requests)
            if (i < _locationHistory.length - 1) {
              await Future.delayed(Duration(milliseconds: 300));
            }
          } catch (e) {
            if (kDebugMode) print('❌ Error resolving address for location $i: $e');
          }
        }
      }
      
      if (hasUpdates && mounted) {
        if (kDebugMode) print('🔄 Updating UI with ${resolvedCount} resolved addresses...');
        setState(() {
          // Trigger rebuild with resolved addresses
          _locationHistory = [..._locationHistory];
        });
      } else if (kDebugMode) {
        print('ℹ️ No updates to apply');
      }
    } catch (e) {
      if (kDebugMode) print('❌ Error in address resolution loop: $e');
    }
  }

  // Reverse geocode using Nominatim (OpenStreetMap). Returns display_name or null.
  Future<String?> _reverseGeocode(double lat, double lng) async {
    try {
      // Use Nominatim's reverse geocoding API
      final url = Uri.parse('https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lng&zoom=18&addressdetails=0');
      if (kDebugMode) print('🔍 Fetching address for: $lat, $lng');
      
      final resp = await http
          .get(
            url,
            headers: {'User-Agent': 'PetTrackCare/1.0 (pettrackcare.app)'},
          )
          .timeout(
            Duration(seconds: 15),
            onTimeout: () {
              if (kDebugMode) print('⏱️ Reverse geocoding timeout for lat: $lat, lng: $lng');
              throw TimeoutException('Reverse geocoding request timed out after 15 seconds');
            },
          );
      
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final display = body['display_name'];
        if (display is String && display.isNotEmpty) {
          if (kDebugMode) print('✅ Reverse geocoding succeeded: $lat, $lng -> $display');
          return display;
        } else {
          if (kDebugMode) print('⚠️ No display_name in response for $lat, $lng');
        }
      } else {
        if (kDebugMode) print('❌ Reverse geocoding failed with status ${resp.statusCode}');
      }
    } catch (e) {
      if (kDebugMode) print('❌ Reverse geocoding error for lat: $lat, lng: $lng: $e');
    }
    return null;
  }

  // Try to resolve address for a specific location in background

  // Format address for display - truncate if too long and prioritize important parts
  String _formatAddressForDisplay(String address) {
    if (address.length <= 60) return address;
    
    // Try to keep the most important parts (first part before first comma)
    final parts = address.split(', ');
    if (parts.isNotEmpty) {
      String formatted = parts[0];
      
      // Add city/area info if available and space permits
      if (parts.length > 2 && formatted.length < 40) {
        formatted += ', ${parts[parts.length - 2]}';
      }
      
      // Add country if space permits
      if (parts.length > 1 && formatted.length < 50) {
        formatted += ', ${parts.last}';
      }
      
      return formatted.length > 60 ? '${formatted.substring(0, 57)}...' : formatted;
    }
    
    return address.length > 60 ? '${address.substring(0, 57)}...' : address;
  }

  // Refresh addresses for location history items that don't have addresses yet
  Future<void> _refreshAddressesForLocationHistory() async {
    // Use the new parallel address resolution method
    await _resolveAddressesForLocationHistory();
  }

  String _formatTimestamp(DateTime? dt) {
    if (dt == null) return '-';
    try {
      return DateFormat('MMM d, yyyy • hh:mm a').format(dt);
    } catch (_) {
      return dt.toString();
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
            ? DateFormat('MMM d, HH:mm').format(_latestDeviceTimestamp!) 
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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _fetchPets();
    // Register callback for when location data is migrated from Firebase
    _autoMigrationService.setOnLocationDataMigrated(() {
      print('🔄 Location data migration callback triggered - refreshing location display');
      // Clear location cache to force fresh fetch
      _clearLocationCache();
      // Refresh location display when migration completes
      if (_selectedPet != null && mounted) {
        _fetchLatestLocationForPet();
      }
    });
    
    // Trigger auto-migration when PetProfileScreen loads
    _runAutoMigrationInBackground();
  }
  
  /// Run auto-migration in background without blocking the UI
  void _runAutoMigrationInBackground() {
    // Use multiple logging methods to ensure visibility
    print('=== AUTO-MIGRATION TRIGGER FROM PETS_SCREEN ===');
    debugPrint('AUTO-MIGRATION TRIGGER CALLED FROM PetProfileScreen.initState()');
    print('Timestamp: ${DateTime.now().toIso8601String()}');
    print('User: ${Supabase.instance.client.auth.currentUser?.id ?? "No user"}');
    print('User Email: ${Supabase.instance.client.auth.currentUser?.email ?? "No email"}');
    
    Future.microtask(() async {
      try {
        print('=== MIGRATION STATUS CHECK ===');
        await _autoMigrationService.checkMigrationStatus();
        
        print('=== CHECKING MIGRATION CONDITIONS ===');
        debugPrint('Starting auto-migration check...');
        
        final shouldRun = await _autoMigrationService.shouldRunMigration();
        print('MIGRATION DECISION: ${shouldRun ? "SHOULD RUN" : "SHOULD NOT RUN"}');
        debugPrint('Migration decision: ${shouldRun ? "SHOULD RUN" : "SHOULD NOT RUN"}');
        
        if (shouldRun) {
          print('=== STARTING MIGRATION PROCESS ===');
          debugPrint('INITIATING BACKGROUND MIGRATION...');
          await _autoMigrationService.runAutoMigration();
          print('=== MIGRATION COMPLETED ===');
          debugPrint('Background migration process completed');
        } else {
          print('=== MIGRATION SKIPPED ===');
          debugPrint('Auto-migration skipped - conditions not met');
          print('=== CONDITIONS: User not authenticated or wrong role ===');
        }
      } catch (e) {
        print('=== MIGRATION ERROR ===');
        print('Error type: ${e.runtimeType}');
        print('Error details: $e');
        debugPrint('BACKGROUND AUTO-MIGRATION ERROR: $e');
      }
    });
  }

  // Setup realtime listener for selected pet changes
  void _setupSelectedPetListener() {
    if (_selectedPet == null) return;
    
    // Unsubscribe from previous pet channel if exists
    if (_selectedPetChannel != null) {
      _selectedPetChannel!.unsubscribe();
    }
    
    final petId = _selectedPet!['id'];
    
    try {
      _selectedPetChannel = Supabase.instance.client
          .channel('selected_pet_$petId')
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'pets',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'id',
              value: petId,
            ),
            callback: (payload) {
              print('🔄 Real-time update for pet $petId');
              final updated = Map<String, dynamic>.from(payload.newRecord);
              // Update the selected pet with new data
              if (mounted) {
                setState(() {
                  _selectedPet!.addAll(updated);
                });
              }
            },
          )
          .subscribe();
    } catch (e) {
      print('Error setting up pet realtime listener: $e');
    }
  }

  // Setup realtime listener for location history changes
  void _setupLocationHistoryListener() {
    if (_selectedPet == null) return;
    
    // Unsubscribe from previous location history channel if exists
    if (_locationHistoryChannel != null) {
      _locationHistoryChannel!.unsubscribe();
    }
    
    final petId = _selectedPet!['id'];
    
    try {
      _locationHistoryChannel = Supabase.instance.client
          .channel('location_history_$petId')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'location_history',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'pet_id',
              value: petId,
            ),
            callback: (payload) {
              print('📍 Real-time location update for pet $petId');
              // Refresh location data when new location is inserted
              if (mounted) {
                _fetchLatestLocationForPet();
                // Refetch location history to get the new entry
                final deviceId = _selectedPet?['device_id']?.toString();
                if (deviceId != null && deviceId.isNotEmpty) {
                  _fetchLocationHistoryForDevice(deviceId, petId: petId);
                }
              }
            },
          )
          .subscribe();
    } catch (e) {
      print('Error setting up location history realtime listener: $e');
    }
  }

  @override
  void dispose() {
    _emergencyContactController.dispose();
    _rewardAmountController.dispose();
    _customMessageController.dispose();
    _specialNotesController.dispose();
    _tabController.dispose();
    // Unsubscribe from realtime listeners
    if (_selectedPetChannel != null) {
      _selectedPetChannel!.unsubscribe();
    }
    if (_locationHistoryChannel != null) {
      _locationHistoryChannel!.unsubscribe();
    }
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
              child: Text('Cancel', style: TextStyle(color: Colors.red)),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _showConnectDeviceModal(context);
              },
              child: Text('Change Device', style: TextStyle(color: Colors.green)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                _disconnectDevice();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
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
                  child: Text('Cancel', style: TextStyle(color: Colors.red)),
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
                    backgroundColor: Colors.green,
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
          child: Text('Cancel', style: TextStyle(color: Colors.red))
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
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
              'created_at': DateTime.now().toUtc().toIso8601String(),
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

        setState(() {
          _lastMissingPostId = postId;
        });

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
                  _navigateToMissingCommunityPost();
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

  void _navigateToMissingCommunityPost() {
    final postId = _lastMissingPostId;
    if (postId == null) return;
    Navigator.of(context).pushNamed(
      '/community',
      arguments: {'postId': postId, 'scrollToPost': true},
    );
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
        content += 'CRITICAL MISSING PET ALERT\n\n';
        break;
      case 'High':
        content += 'URGENT: MISSING PET ALERT\n\n';
        break;
      case 'Medium':
        content += 'Missing Pet Alert\n\n';
        break;
    }
    
    // Basic info
    if (isOwner) {
      content += 'My beloved pet "$petName" ($breed) is missing!\n\n';
    } else {
      content += 'URGENT: Pet "$petName" ($breed) went missing while under my care as a pet sitter.\n';
    }
    
    // Location and time
    content += 'Last seen: $locationStr\n';
    content += 'Time: $lastSeen\n';
    
    // Custom message if provided
    if (_customMessageController.text.isNotEmpty) {
      content += 'Additional Details: ${_customMessageController.text}\n';
    }
    
    // Special notes if provided
    if (_specialNotesController.text.isNotEmpty) {
      content += 'Important Notes: ${_specialNotesController.text}\n';
    }
    

    
    // Reward info
    if (_hasReward && _rewardAmountController.text.isNotEmpty) {
      content += 'Reward Offered: ₱ ${_rewardAmountController.text}\n';
    }
    
    // Contact info
    if (_emergencyContactController.text.isNotEmpty) {
      content += 'Emergency Contact: ${_emergencyContactController.text}\n';
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
              hintStyle: TextStyle(color: Colors.grey),
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
              hintStyle: TextStyle(color: Colors.grey),
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
              hintStyle: TextStyle(color: Colors.grey),
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
                            'Critical - Immediate danger',
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
                            'High - Just went missing',
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
                            'Medium - Missing for a while',
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
                    ? 'This will create a community alert and notify nearby users. It will also reflect in the pet’s QR code.'
                    : 'This will alert the owner and the community. It will also reflect in the pet’s QR code.',
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
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.red),
                  ),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
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
  Widget _buildInfoRow(IconData icon, String label, String value, {int maxLines = 2}) {
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
              maxLines: maxLines,
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
            Expanded(
              child: Text(
                'Pet Profile',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  fontSize: 20,
                ),
                overflow: TextOverflow.ellipsis,
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
                
                // Save pet selection for future sessions
                _saveSelectedPetId(petId);
                
                // Quick UI update first for immediate response
                setState(() {
                  _selectedPet = pet;
                  // Reset request ID to ensure fresh analysis for new pet
                  _currentAnalysisRequestId = null;
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
                    _moodProb = cachedData['moodProb'] ?? {};
                    _activityProb = cachedData['activityProb'] ?? {};
                    _illnessRisk = cachedData['illnessRisk'];
                    _isUnhealthy = cachedData['isUnhealthy'] ?? false;
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
                                        color: (_petHealthStatus[pet['id']] ?? false)
                                            ? Colors.red.withOpacity(0.2)
                                            : Colors.green.withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        (_petHealthStatus[pet['id']] ?? false) ? 'Bad' : 'Good',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: (_petHealthStatus[pet['id']] ?? false)
                                              ? Colors.red.shade700
                                              : Colors.green.shade700,
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
                            backgroundColor: Colors.green,
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
                              backgroundColor: Colors.green,
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

    // Check if current map location is the same as latest device location (live GPS)
    final isShowingLiveLocation = _currentMapLocation != null && 
                                   _latestDeviceLocation != null &&
                                   _currentMapLocation!.latitude == _latestDeviceLocation!.latitude &&
                                   _currentMapLocation!.longitude == _latestDeviceLocation!.longitude;

    // Prefer latest device location (live GPS) for display
    if (_latestDeviceLocation != null && (isShowingLiveLocation || _currentMapLocation == null)) {
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
      markerSub = _latestDeviceTimestamp != null ? DateFormat('MMM d, yyyy • h:mm a').format(_latestDeviceTimestamp!) : 'Last seen: unknown';
    } else if (_currentMapLocation != null) {
      // Showing a historical location (user clicked on a location from history)
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
                            key: ValueKey('map_${lat}_${lng}_${_selectedPet?['id']}'),
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
      // Show formatted address as title, coordinates as subtitle for precision
      title = _formatAddressForDisplay(address);
      subtitle = lat != null && lng != null 
          ? 'Coordinates: ${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}'
          : 'Address resolved';
      leadingIcon = Icons.location_on;
      iconColor = deepRed;
    } else if (lat != null && lng != null) {
      // Show coordinates as title when no address is available yet
      title = 'Lat: ${lat.toStringAsFixed(4)}, Lng: ${lng.toStringAsFixed(4)}';
      subtitle = 'Resolving address...';
      leadingIcon = Icons.my_location;
      iconColor = Colors.orange;
      // Note: Address resolution is now handled by _resolveAddressesForLocationHistory() after fetch completes
    } else {
      title = 'Unknown Location';
      subtitle = 'No location data available';
      leadingIcon = Icons.location_off;
      iconColor = Colors.grey;
    }
    
    // Format actual timestamp instead of relative time
    String timestampDisplay = 'Unknown time';
    if (timestamp != null) {
      try {
        // Format as: Oct 5, 2025 • 2:30 PM
        // The timestamp already has the correct local time, so don't convert it again
        // Just use it directly without timezone conversion
        timestampDisplay = DateFormat('MMM d, yyyy • h:mm a').format(timestamp);
      } catch (e) {
        // Fallback to ISO string if formatting fails
        timestampDisplay = timestamp.toString().substring(0, 16);
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
                  timestampDisplay,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade500,
                    fontWeight: FontWeight.w500,
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
                    _updateMapView(LatLng(lat, lng), title, timestampDisplay);
                  },
                ),
              )
            : null,
        onTap: lat != null && lng != null 
            ? () {
                _updateMapView(LatLng(lat, lng), title, timestampDisplay);
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

    final baseBackend = backendUrl.replaceAll(RegExp(r'/analyze/?\$'), '');
    final payloadStr = '$baseBackend/pet/${_selectedPet!['id']}';

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
                              'Pet ID & Missing Info',
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
                    'Anyone can scan to view pet information and missing alerts.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey,
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
                            backgroundColor: Colors.green,
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
                            'Link: $payloadStr',
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
      _activityLevel = null;
      _foodIntake = null;
      _waterIntake = null;
      _bathroomHabits = null;
      _selectedSymptoms = [];
    });
  }

  // Read-only modal showing existing behavior with Edit/Delete
  void _showExistingBehaviorModal(BuildContext context, Map<String, dynamic> log) {
    final activity = (log['activity_level'] ?? '').toString();
    final notes = (log['notes'] ?? '').toString();
    final foodIntake = (log['food_intake'] ?? '').toString();
    final waterIntake = (log['water_intake'] ?? '').toString();
    final bathroomHabits = (log['bathroom_habits'] ?? '').toString();
    final rawDate = (log['log_date'] ?? '').toString();
    final createdAt = log['created_at']?.toString();
    
    // Parse symptoms
    List<String> symptoms = [];
    final symptomsData = log['symptoms'];
    if (symptomsData != null) {
      if (symptomsData is List) {
        symptoms = List<String>.from(symptomsData);
      } else if (symptomsData is String) {
        try {
          final decoded = json.decode(symptomsData);
          if (decoded is List) {
            symptoms = List<String>.from(decoded);
          } else {
            symptoms = symptomsData.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
          }
        } catch (_) {
          symptoms = symptomsData.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        }
      }
    }
    
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
                      // Food Intake Section
                      _buildDetailCard(
                        title: 'Food Intake',
                        icon: Icons.restaurant,
                        iconColor: Colors.orange,
                        value: foodIntake.isEmpty ? 'Not recorded' : foodIntake,
                        isEmpty: foodIntake.isEmpty,
                      ),

                      SizedBox(height: 16),

                      // Water Intake Section
                      _buildDetailCard(
                        title: 'Water Intake',
                        icon: Icons.water_drop,
                        iconColor: Colors.blue,
                        value: waterIntake.isEmpty ? 'Not recorded' : waterIntake,
                        isEmpty: waterIntake.isEmpty,
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

                      // Bathroom Habits Section
                      _buildDetailCard(
                        title: 'Bathroom Habits',
                        icon: Icons.health_and_safety,
                        iconColor: Colors.teal,
                        value: bathroomHabits.isEmpty ? 'Not recorded' : bathroomHabits,
                        isEmpty: bathroomHabits.isEmpty,
                      ),

                      SizedBox(height: 16),

                      // Symptoms Section
                      if (symptoms.isNotEmpty) ...[
                        _buildDetailCard(
                          title: 'Clinical Signs',
                          icon: Icons.medical_services,
                          iconColor: Colors.red,
                          value: symptoms.join(', '),
                          isEmpty: false,
                        ),
                        SizedBox(height: 16),
                      ],

                      // Notes Section
                      if (notes.isNotEmpty) ...[
                        _buildDetailCard(
                          title: 'Notes',
                          icon: Icons.note_alt,
                          iconColor: Colors.indigo,
                          value: notes,
                          isNote: true,
                          isEmpty: false,
                        ),
                        SizedBox(height: 16),
                      ],

                      // Health Insights
                      _buildHealthInsights(activity, foodIntake, waterIntake, bathroomHabits, symptoms),

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
  Widget _buildHealthInsights(String activity, String foodIntake, String waterIntake, String bathroomHabits, List<String> symptoms) {
    List<Widget> insights = [];
    
    // Normalize strings for case-insensitive comparison
    final normalizedFood = foodIntake.trim().toLowerCase();
    final normalizedWater = waterIntake.trim().toLowerCase();
    final normalizedActivity = activity.trim().toLowerCase();
    final normalizedBathroom = bathroomHabits.trim().toLowerCase();
    
    // Food intake insights
    if (normalizedFood.contains('not eating') || normalizedFood.contains('eating less')) {
      insights.add(_buildInsightItem(
        'Food Intake Concern',
        'Reduced appetite may indicate health issues. Monitor closely.',
        Icons.warning,
        Colors.red,
      ));
    }

    // Water intake insights
    if (normalizedWater.contains('not drinking') || normalizedWater.contains('drinking less')) {
      insights.add(_buildInsightItem(
        'Hydration Concern',
        'Reduced water intake needs attention. Ensure fresh water is available.',
        Icons.warning,
        Colors.red,
      ));
    } else if (normalizedWater.contains('drinking more')) {
      insights.add(_buildInsightItem(
        'Increased Thirst',
        'Excessive drinking may indicate diabetes or kidney issues. Consider a vet visit.',
        Icons.info,
        Colors.orange,
      ));
    }

    // Bathroom habits insights

    if (normalizedBathroom.contains('diarrhea')) {
      insights.add(_buildInsightItem(
        'Diarrhea Observed',
        'Loose stools can indicate sensitive digestion, infection, or dietary upset; track frequency and mucus/blood.',
        Icons.health_and_safety,
        Colors.red,
      ));
    }
    if (normalizedBathroom.contains('constipation')) {
      insights.add(_buildInsightItem(
        'Constipation Warning',
        'Hard or infrequent stools may require increased fiber, hydration, or veterinary review.',
        Icons.health_and_safety,
        Colors.orange,
      ));
    }
    if (normalizedBathroom.contains('frequent urination') ||
        (normalizedBathroom.contains('frequent') && normalizedBathroom.contains('urination'))) {
      insights.add(_buildInsightItem(
        'Frequent Urination',
        'Frequent trips to pee can signal a urinary tract issue or diabetes; note color, volume, and wet spots.',
        Icons.water_drop,
        Colors.orange,
      ));
    }
    if (normalizedBathroom.contains('straining')) {
      insights.add(_buildInsightItem(
        'Straining to Go',
        'Straining may mean discomfort, a blockage, or inflammation; do not delay a vet check if it continues.',
        Icons.warning,
        Colors.red,
      ));
    }
    if (normalizedBathroom.contains('blood')) {
      insights.add(_buildInsightItem(
        'Blood in Urine or Stool',
        'Blood indicates a serious concern—seek veterinary care immediately to identify the source.',
        Icons.error,
        Colors.red,
      ));
    }
    if (normalizedBathroom.contains('accident') || normalizedBathroom.contains('soiling') || normalizedBathroom.contains('house soiling')) {
      insights.add(_buildInsightItem(
        'House Soiling or Accidents',
        'Inappropriate toileting can point to stress, urinary issues, or mobility changes—record where/when it happens.',
        Icons.home,
        Colors.orange,
      ));
    }
    // Activity insights
    if (normalizedActivity.contains('low')) {
      insights.add(_buildInsightItem(
        'Low Activity Level',
        'Consider encouraging more exercise or check for health issues.',
        Icons.trending_down,
        Colors.orange,
      ));
    } else if (normalizedActivity.contains('high')) {
      insights.add(_buildInsightItem(
        'High Energy',
        'Great! Your pet is active and energetic.',
        Icons.trending_up,
        Colors.green,
      ));
    }

    // Symptoms insights - filter out "None of the Above"
    final actualSymptoms = symptoms.where((s) => s.toLowerCase() != "none of the above").toList();
    if (actualSymptoms.isNotEmpty) {
      insights.add(_buildInsightItem(
        'Clinical Signs Reported',
        '${actualSymptoms.length} clinical sign(s) detected. Please monitor and consult a vet if they persist or worsen.',
        Icons.medical_services,
        Colors.red,
      ));
    }

    if (insights.isEmpty) {
      insights.add(_buildInsightItem(
        'Normal Patterns',
        'All logged health data appears within normal ranges.',
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

  // Build health insights as a list of widgets (for state-based rendering)
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
            child: Text('Cancel', style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
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
          // _fetchLatestAnalysis() removed - predictions table deprecated
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
            // Daily Logging Reminder Banner
            Container(
              margin: EdgeInsets.all(8),
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: peach.withOpacity(0.3),
                border: Border.all(
                  color: coral,
                  width: 1.5,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: coral.withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.calendar_today,
                      color: deepRed,
                      size: 20,
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Daily Logging Tip',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: deepRed,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Log data every day for best results. Daily entries help us understand your pet\'s health patterns better.',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade700,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            SizedBox(height: 8),

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
            
            // Enhanced Latest Analysis Section - always display
            ...[
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
          SizedBox(height: 16),
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
                "Analysis Results",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  color: deepRed,
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
          
          // Display data sufficiency notice if present
          if (_dataNotice != null) ...[
            _buildDataNoticeCard(_dataNotice!),
            SizedBox(height: 12),
          ],
          
          // Display illness risk notice if present and pet is unhealthy
          if (_illnessRiskNotice != null && _isUnhealthy) ...[
            _buildIllnessRiskNoticeCard(_illnessRiskNotice!),
            SizedBox(height: 12),
          ],
          
          // Health Status Section (moved inside Latest Analysis)
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: _isUnhealthy 
                  ? [deepRed.withOpacity(0.1), coral.withOpacity(0.1)]
                  : [Colors.green.withOpacity(0.1), Colors.lightGreen.withOpacity(0.1)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _isUnhealthy ? deepRed.withOpacity(0.3) : Colors.green.withOpacity(0.3),
                width: 1.5,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _isUnhealthy ? deepRed : Colors.green,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isUnhealthy ? Icons.warning : Icons.favorite,
                    color: Colors.white,
                    size: 20,
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
                          fontSize: 15,
                          color: _isUnhealthy ? deepRed : Colors.green.shade700,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        _getHealthStatusMessage(),
                        style: TextStyle(
                          fontSize: 13,
                          color: _isUnhealthy ? deepRed.withOpacity(0.8) : Colors.green.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          // Display health guidance based on detected symptoms - only if pet is unhealthy
          if (_healthGuidance != null && _isUnhealthy) ...[
            SizedBox(height: 12),
            _buildHealthGuidanceCard(_healthGuidance!),
            SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  // Health Insights Widget (moved after Latest Analysis)

  // Helper method to get health status message based on illness risk
  String _getHealthStatusMessage() {
    if (!_isUnhealthy) {
      return "No illness predicted — pet appears healthy";
    }
    
    final risk = _illnessRisk?.toLowerCase() ?? 'unknown';
    
    if (risk == 'high') {
      return 'Veterinary consultation recommended. Pet may need immediate care.';
    } else if (risk == 'medium') {
      return 'Monitor closely. Pet may need care within 24-48 hours.';
    } else {
      return 'Illness risk: ${_illnessRisk ?? 'Unknown'}';
    }
  }
  
  // Build data sufficiency notice card
  Widget _buildDataNoticeCard(Map<String, dynamic> notice) {
    final status = notice['status']?.toString() ?? 'unknown';
    final message = notice['message']?.toString() ?? '';
    
    // Determine color based on status
    Color cardColor;
    IconData iconData;
    
    if (status == 'insufficient_data') {
      cardColor = Colors.orange;
      iconData = Icons.info;
    } else {
      cardColor = Colors.green;
      iconData = Icons.check_circle;
    }
    
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cardColor.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(iconData, color: cardColor, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cardColor,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
  
  Widget _buildIllnessRiskNoticeCard(Map<String, dynamic> notice) {
    final status = notice['status']?.toString() ?? 'unknown';
    final message = notice['message']?.toString() ?? '';
    final bool isPersistent = notice['is_persistent'] ?? false;
    final int? persistenceDays = (notice['persistence_days'] as num?)?.toInt();
    
    // Determine color based on risk status
    Color cardColor;
    IconData iconData;
    
    if (status == 'high_risk') {
      cardColor = Color(0xFFB82132); // deep red
      iconData = Icons.error;
    } else if (status == 'medium_risk') {
      cardColor = Color(0xFFFF8C00); // orange
      iconData = Icons.warning;
    } else {
      cardColor = Color(0xFF2ECC71); // green
      iconData = Icons.check_circle;
    }
    
    // Build persistence indicator if present
    String persistenceText = '';
    if (isPersistent && persistenceDays != null && persistenceDays > 0) {
      final dayLabel = '$persistenceDays day${persistenceDays == 1 ? '' : 's'}';
      persistenceText = ' (Persistent for $dayLabel)';
    }
    
    final displayMessage = message + persistenceText;
    
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cardColor, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(iconData, color: cardColor, size: 22),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  displayMessage,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cardColor,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHealthGuidanceCard(Map<String, dynamic> guidance) {
    final urgency = guidance['urgency']?.toString() ?? 'none';
    final detectedSymptoms = (guidance['detected_symptoms'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
    final recommendations = (guidance['recommendations'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
    final detectedHealthIssues = (guidance['detected_health_issues'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
    final int? illnessDurationDays = (guidance['illness_duration_days'] as num?)?.toInt();
    final bool persistentIllness = guidance['is_persistent_illness'] == true;
    String? analysisCoverage;
    if (illnessDurationDays != null && illnessDurationDays > 0) {
      final durationLabel = '$illnessDurationDays day${illnessDurationDays == 1 ? '' : 's'}';
      analysisCoverage = persistentIllness
          ? 'Health concerns persistent for $durationLabel of unhealthy logs.'
          : 'Health concerns based on $durationLabel of recent logs.';
    }
    
    // Determine urgency color
    Color urgencyColor;
    IconData urgencyIcon;
    
    if (urgency == 'critical') {
      urgencyColor = Color(0xFFD32F2F); // Deep red
      urgencyIcon = Icons.emergency;
    } else if (urgency == 'high') {
      urgencyColor = Color(0xFFF57C00); // Orange
      urgencyIcon = Icons.warning;
    } else if (urgency == 'medium') {
      urgencyColor = Color(0xFFFBC02D); // Amber
      urgencyIcon = Icons.info;
    } else {
      urgencyColor = Color(0xFF388E3C); // Green
      urgencyIcon = Icons.check_circle;
    }
    
    // Get default care tips based on urgency level
    List<String> careTips = _getDefaultCareTips(urgency);
    
    // Merge recommendations into care tips for non-redundant display
    if (recommendations.isNotEmpty) {
      careTips.insertAll(0, recommendations);
    }
    
    return Container(
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Color(0xFFB82132).withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Color(0xFFB82132).withOpacity(0.3),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with icon and title
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(urgencyIcon, color: Color(0xFFB82132), size: 24),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Health Guidance',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFB82132),
                  ),
                ),
              ),
            ],
          ),

          if (analysisCoverage != null) ...[
            SizedBox(height: 6),
            Padding(
              padding: EdgeInsets.only(left: 30),
              child: Text(
                analysisCoverage,
                style: TextStyle(
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                  color: Color(0xFFB82132).withOpacity(0.85),
                ),
              ),
            ),
          ],
          
          // Detected health issues (problems/concerns that may cause illness)
          if (detectedHealthIssues.isNotEmpty) ...[
            SizedBox(height: 10),
            Padding(
              padding: EdgeInsets.only(left: 30),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Health Concerns Detected:',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFB82132),
                    ),
                  ),
                  SizedBox(height: 8),
                  ...detectedHealthIssues.take(5).map((issue) => Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Text(
                      '• $issue',
                      style: TextStyle(
                        fontSize: 13,
                        color: Color(0xFFB82132).withOpacity(0.85),
                        height: 1.4,
                      ),
                    ),
                  )).toList(),
                ],
              ),
            ),
          ],
          
          // Detected clinical symptoms (actual physical signs)
          if (detectedSymptoms.isNotEmpty) ...[
            SizedBox(height: 10),
            Padding(
              padding: EdgeInsets.only(left: 30),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Detected Clinical Signs:',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFB82132),
                    ),
                  ),
                  SizedBox(height: 8),
                  ...detectedSymptoms.take(5).map((symptom) => Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Text(
                      '• $symptom',
                      style: TextStyle(
                        fontSize: 13,
                        color: Color(0xFFB82132).withOpacity(0.85),
                        height: 1.4,
                      ),
                    ),
                  )).toList(),
                ],
              ),
            ),
          ],
          
          // General care tips (includes merged recommendations and default tips)
          if (careTips.isNotEmpty) ...[
            SizedBox(height: 12),
            Padding(
              padding: EdgeInsets.only(left: 30),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Care Tips:',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFB82132),
                    ),
                  ),
                  SizedBox(height: 8),
                  ...careTips.map((tip) => Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: _buildCareTip(tip, urgencyColor),
                  )).toList(),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
  
  List<String> _getDefaultCareTips(String urgency) {
    switch (urgency.toLowerCase()) {
      case 'critical':
        return [
          '[ALERT] Seek immediate veterinary care - do not delay',
          '[ALERT] Keep your pet calm and minimize physical activity',
          '[INFO] Have your pet\'s medical history ready for the vet',
          '[INFO] Monitor vital signs (breathing, temperature, hydration)',
          '[WARNING] Avoid giving new food or treats during this period',
          '[INFO] Keep your pet in a quiet, comfortable environment',
          '[TIP] Document all symptoms and when they started',
        ];
      case 'high':
        return [
          '[WARNING] Schedule a veterinary appointment urgently',
          '[INFO] Monitor your pet closely for any changes',
          '[INFO] Maintain regular meal schedules and hydration',
          '[TIP] Take photos or video of symptoms to show the vet',
          '[INFO] Avoid strenuous exercise and play',
          '[WARNING] Do not give medications without vet approval',
          '[TIP] Keep a daily log of symptoms and behavior changes',
        ];
      case 'medium':
        return [
          '[INFO] Schedule a veterinary checkup within the next few days',
          '[INFO] Monitor symptoms for any worsening',
          '[TIP] Maintain consistent feeding and water schedules',
          '[INFO] Provide a comfortable resting area',
          '[INFO] Keep your pet clean and well-groomed',
          '[TIP] Document symptom patterns and triggers',
          '[INFO] Avoid sudden changes to diet or routine',
        ];
      default:
        return [
          '[OK] Continue regular health maintenance and monitoring',
          '[TIP] Maintain consistent exercise and play routines',
          '[INFO] Keep regular grooming and hygiene practices',
          '[INFO] Schedule annual preventive health checkups',
          '[TIP] Provide balanced nutrition and fresh water daily',
          '[INFO] Monitor your pet\'s behavior regularly',
          '[TIP] Keep your pet\'s vaccinations up to date',
        ];
    }
  }
  
  
  Widget _buildCareTip(String tip, Color defaultColor) {
    // Parse tip text for icon tags
    String text = tip;
    IconData? iconData;
    Color iconColor = defaultColor;
    
    // Check for icon tags and replace them
    if (text.contains('[ALERT]')) {
      iconData = Icons.warning;
      iconColor = Color(0xFFFF8C00); // Orange
      text = text.replaceAll('[ALERT]', '').trim();
    } else if (text.contains('[ERROR]')) {
      iconData = Icons.error;
      iconColor = Color(0xFFB82132); // Red
      text = text.replaceAll('[ERROR]', '').trim();
    } else if (text.contains('[OK]')) {
      iconData = Icons.check_circle;
      iconColor = Color(0xFF2ECC71); // Green
      text = text.replaceAll('[OK]', '').trim();
    } else if (text.contains('[INFO]')) {
      iconData = Icons.info;
      iconColor = Color(0xFF1E88E5); // Blue
      text = text.replaceAll('[INFO]', '').trim();
    } else if (text.contains('[WARNING]')) {
      iconData = Icons.warning_amber;
      iconColor = Color(0xFFFBC02D); // Amber
      text = text.replaceAll('[WARNING]', '').trim();
    } else if (text.contains('[TIP]')) {
      iconData = Icons.lightbulb;
      iconColor = Color(0xFFFBC02D); // Amber
      text = text.replaceAll('[TIP]', '').trim();
    } else if (text.contains('[HELP]')) {
      iconData = Icons.help;
      iconColor = Color(0xFF1E88E5); // Blue
      text = text.replaceAll('[HELP]', '').trim();
    }
    
    // Default icon if no tag found
    if (iconData == null) {
      iconData = Icons.check;
      iconColor = defaultColor.withOpacity(0.6);
    }
    
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(iconData, color: iconColor, size: 16),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: Color(0xFFB82132).withOpacity(0.85),
              height: 1.5,
            ),
          ),
        ),
      ],
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

  // Extend logging modal to support edit/update when 'existing' is provided
  void _showBehaviorModal(BuildContext context, DateTime selectedDate, {Map<String, dynamic>? existing}) {
    // Initialize form values from existing data if editing
    if (existing != null) {
      _activityLevel = existing['activity_level']?.toString();
      _foodIntake = existing['food_intake']?.toString();
      _waterIntake = existing['water_intake']?.toString();
      _bathroomHabits = existing['bathroom_habits']?.toString();
      
      
      // Parse symptoms from JSON string or comma-separated string
      final symptomsData = existing['symptoms'];
      if (symptomsData != null) {
        if (symptomsData is List) {
          _selectedSymptoms = List<String>.from(symptomsData);
        } else if (symptomsData is String) {
          try {
            // Try to parse as JSON array first
            final decoded = json.decode(symptomsData);
            if (decoded is List) {
              _selectedSymptoms = List<String>.from(decoded);
            } else {
              _selectedSymptoms = symptomsData.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
            }
          } catch (_) {
            // Fall back to comma-separated
            _selectedSymptoms = symptomsData.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
          }
        }
      }
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
              // All fields must be filled including clinical signs (symptoms)
              return _activityLevel != null && 
                     _foodIntake != null && 
                     _waterIntake != null && 
                     _bathroomHabits != null &&
                     _selectedSymptoms.isNotEmpty; // Clinical signs required
            }

            return AnimatedContainer(
              duration: Duration(milliseconds: 300),
              height: MediaQuery.of(context).size.height * 0.90,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.20),
                    blurRadius: 30,
                    spreadRadius: 8,
                    offset: Offset(0, -8),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Handle bar
                  Container(
                    margin: EdgeInsets.only(top: 14),
                    width: 50,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  
                  // Pet Health Status Header
                  Container(
                    padding: EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Color(0xFFB82132),
                          Color(0xFFD2665A),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Status indicator
                        Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.25),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                _isUnhealthy ? Icons.warning_rounded : Icons.health_and_safety,
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
                                    _selectedPet?['name'] ?? 'Your Pet',
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    'Health Status: ${_isUnhealthy ? "Needs Attention" : "✓ Looking Good"}',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.white.withOpacity(0.9),
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: Icon(Icons.close, color: Colors.white),
                              onPressed: () => Navigator.pop(context),
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.white.withOpacity(0.2),
                                shape: CircleBorder(),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 16),
                        // Date
                        Row(
                          children: [
                            Icon(Icons.calendar_today, color: Colors.white.withOpacity(0.8), size: 16),
                            SizedBox(width: 8),
                            Text(
                              DateFormat('EEEE, MMMM d, yyyy').format(selectedDate),
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: Colors.white.withOpacity(0.9),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  
                  // Form Title
                  Container(
                    padding: EdgeInsets.fromLTRB(24, 20, 24, 12),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: Colors.grey.shade200, width: 1)),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isEdit ? Icons.edit_note_rounded : Icons.note_add_rounded,
                          color: deepRed,
                          size: 20,
                        ),
                        SizedBox(width: 10),
                        Text(
                          isEdit ? 'Update Health Log' : 'Log Pet Health Data',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade800,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Form content
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(20, 16, 20, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Food Intake Section
                          _buildFormSection(
                            title: "Food Intake",
                            icon: Icons.restaurant,
                            iconColor: Colors.orange,
                            subtitle: "Is ${_selectedPet?['name'] ?? 'your pet'} eating well?",
                            child: Column(
                              children: [
                                SizedBox(height: 12),
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    double itemWidth = (constraints.maxWidth - 12) / 2;
                                    return Wrap(
                                      spacing: 12,
                                      runSpacing: 12,
                                      children: foodIntakeOptions.map((intake) {
                                    final selected = _foodIntake == intake;
                                    IconData iconData;
                                    Color iconColor;
                                    
                                    switch(intake) {
                                      case "Not eating / Loss of appetite":
                                        iconData = Icons.close_rounded;
                                        iconColor = Colors.red;
                                        break;
                                      case "Eating less than usual":
                                        iconData = Icons.trending_down;
                                        iconColor = Colors.orange;
                                        break;
                                      case "Normal eating":
                                        iconData = Icons.check_circle_outline;
                                        iconColor = Colors.green;
                                        break;
                                      case "Eating more than usual":
                                        iconData = Icons.trending_up;
                                        iconColor = Colors.blue;
                                        break;
                                      case "Sudden weight loss":
                                        iconData = Icons.trending_down;
                                        iconColor = Colors.red;
                                        break;
                                      case "Sudden weight gain":
                                        iconData = Icons.trending_up;
                                        iconColor = Colors.orange;
                                        break;
                                      default:
                                        iconData = Icons.circle_outlined;
                                        iconColor = Colors.grey;
                                    }
                                    
                                    return SizedBox(
                                      width: itemWidth,
                                      child: GestureDetector(
                                        onTap: () {
                                          setModalState(() => _foodIntake = intake);
                                          setState(() => _foodIntake = intake);
                                          HapticFeedback.lightImpact();
                                        },
                                        child: MouseRegion(
                                          cursor: SystemMouseCursors.click,
                                          child: AnimatedContainer(
                                            duration: Duration(milliseconds: 250),
                                            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                            decoration: BoxDecoration(
                                              color: selected 
                                                ? Colors.orange.withOpacity(0.12) 
                                                : Colors.grey.shade50,
                                              border: Border.all(
                                                color: selected 
                                                  ? Colors.orange.shade600
                                                  : Colors.grey.shade300,
                                                width: selected ? 2.5 : 1.5,
                                              ),
                                              borderRadius: BorderRadius.circular(12),
                                              boxShadow: selected ? [
                                                BoxShadow(
                                                  color: Colors.orange.withOpacity(0.15),
                                                  blurRadius: 8,
                                                  offset: Offset(0, 2),
                                                ),
                                              ] : null,
                                            ),
                                            child: Row(
                                              children: [
                                                Container(
                                                  padding: EdgeInsets.all(8),
                                                  decoration: BoxDecoration(
                                                    color: selected 
                                                      ? iconColor.withOpacity(0.25)
                                                      : Colors.grey.shade200,
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  child: Icon(
                                                    iconData,
                                                    color: selected ? iconColor : Colors.grey.shade500,
                                                    size: 22,
                                                  ),
                                                ),
                                                SizedBox(width: 14),
                                                Expanded(
                                                  child: Text(
                                                    intake,
                                                    style: TextStyle(
                                                      fontSize: 15,
                                                      fontWeight: selected 
                                                        ? FontWeight.w700 
                                                        : FontWeight.w500,
                                                      color: selected 
                                                        ? Colors.orange.shade900
                                                        : Colors.grey.shade700,
                                                    ),
                                                  ),
                                                ),
                                                if (selected)
                                                  Container(
                                                    padding: EdgeInsets.all(4),
                                                    decoration: BoxDecoration(
                                                      color: Colors.orange.shade600,
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
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),

                          SizedBox(height: 20),

                          // Water Intake Section
                          _buildFormSection(
                            title: "Water Intake",
                            icon: Icons.water_drop,
                            iconColor: Colors.blue,
                            subtitle: "Monitor drinking patterns",
                            child: Column(
                              children: [
                                SizedBox(height: 12),
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    double itemWidth = (constraints.maxWidth - 12) / 2;
                                    return Wrap(
                                      spacing: 12,
                                      runSpacing: 12,
                                      children: waterIntakeOptions.map((intake) {
                                    final selected = _waterIntake == intake;
                                    IconData iconData;
                                    Color iconColor;
                                    
                                    switch(intake) {
                                      case "Not drinking":
                                        iconData = Icons.close_rounded;
                                        iconColor = Colors.red;
                                        break;
                                      case "Drinking less than usual":
                                        iconData = Icons.trending_down;
                                        iconColor = Colors.orange;
                                        break;
                                      case "Normal drinking":
                                        iconData = Icons.check_circle_outline;
                                        iconColor = Colors.blue;
                                        break;
                                      case "Excessive drinking (increased thirst)":
                                        iconData = Icons.trending_up;
                                        iconColor = Colors.purple;
                                        break;
                                      default:
                                        iconData = Icons.circle_outlined;
                                        iconColor = Colors.grey;
                                    }
                                    
                                    return SizedBox(
                                      width: itemWidth,
                                      child: GestureDetector(
                                        onTap: () {
                                          setModalState(() => _waterIntake = intake);
                                          setState(() => _waterIntake = intake);
                                          HapticFeedback.lightImpact();
                                        },
                                        child: MouseRegion(
                                          cursor: SystemMouseCursors.click,
                                          child: AnimatedContainer(
                                            duration: Duration(milliseconds: 250),
                                            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                            decoration: BoxDecoration(
                                              color: selected 
                                                ? Colors.blue.withOpacity(0.12) 
                                                : Colors.grey.shade50,
                                              border: Border.all(
                                                color: selected 
                                                  ? Colors.blue.shade600
                                                  : Colors.grey.shade300,
                                                width: selected ? 2.5 : 1.5,
                                              ),
                                              borderRadius: BorderRadius.circular(12),
                                              boxShadow: selected ? [
                                                BoxShadow(
                                                  color: Colors.blue.withOpacity(0.15),
                                                  blurRadius: 8,
                                                  offset: Offset(0, 2),
                                                ),
                                              ] : null,
                                            ),
                                            child: Row(
                                              children: [
                                                Container(
                                                  padding: EdgeInsets.all(8),
                                                  decoration: BoxDecoration(
                                                    color: selected 
                                                      ? iconColor.withOpacity(0.25)
                                                      : Colors.grey.shade200,
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  child: Icon(
                                                    iconData,
                                                    color: selected ? iconColor : Colors.grey.shade500,
                                                    size: 22,
                                                  ),
                                                ),
                                                SizedBox(width: 14),
                                                Expanded(
                                                  child: Text(
                                                    intake,
                                                    style: TextStyle(
                                                      fontSize: 15,
                                                      fontWeight: selected 
                                                        ? FontWeight.w700 
                                                        : FontWeight.w500,
                                                      color: selected 
                                                        ? Colors.blue.shade900
                                                        : Colors.grey.shade700,
                                                    ),
                                                  ),
                                                ),
                                                if (selected)
                                                  Container(
                                                    padding: EdgeInsets.all(4),
                                                    decoration: BoxDecoration(
                                                      color: Colors.blue.shade600,
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
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),

                          SizedBox(height: 20),

                          // Bathroom Habits Section
                          _buildFormSection(
                            title: "Bathroom Habits",
                            icon: Icons.health_and_safety,
                            iconColor: Colors.purple,
                            subtitle: "Track bathroom changes",
                            child: Column(
                              children: [
                                SizedBox(height: 12),
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    double itemWidth = (constraints.maxWidth - 12) / 2;
                                    return Wrap(
                                      spacing: 12,
                                      runSpacing: 12,
                                      children: bathroomOptions.map((habit) {
                                    final selected = _bathroomHabits == habit;
                                    IconData iconData;
                                    Color habitColor;
                                    
                                    switch(habit) {
                                      case "Normal urination/defecation":
                                        iconData = Icons.check_circle_outline;
                                        habitColor = Colors.green;
                                        break;
                                      case "Diarrhea":
                                        iconData = Icons.warning_amber_rounded;
                                        habitColor = Colors.orange;
                                        break;
                                      case "Constipation":
                                        iconData = Icons.block;
                                        habitColor = Colors.red;
                                        break;
                                      case "Frequent urination":
                                        iconData = Icons.repeat_rounded;
                                        habitColor = Colors.purple;
                                        break;
                                      case "Straining to urinate":
                                        iconData = Icons.error_outline;
                                        habitColor = Colors.red;
                                        break;
                                      case "Blood in urine":
                                        iconData = Icons.priority_high;
                                        habitColor = Colors.red;
                                        break;
                                      case "House soiling / accidents":
                                        iconData = Icons.warning;
                                        habitColor = Colors.orange;
                                        break;
                                      default:
                                        iconData = Icons.circle_outlined;
                                        habitColor = Colors.grey;
                                    }
                                    
                                    return SizedBox(
                                      width: itemWidth,
                                      child: GestureDetector(
                                        onTap: () {
                                          setModalState(() => _bathroomHabits = habit);
                                          setState(() => _bathroomHabits = habit);
                                          HapticFeedback.lightImpact();
                                        },
                                        child: MouseRegion(
                                          cursor: SystemMouseCursors.click,
                                          child: AnimatedContainer(
                                            duration: Duration(milliseconds: 250),
                                            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                            decoration: BoxDecoration(
                                              color: selected 
                                                ? Colors.purple.withOpacity(0.15) 
                                                : Colors.grey.shade50,
                                              border: Border.all(
                                                color: selected 
                                                  ? Colors.purple.shade600
                                                  : Colors.grey.shade300,
                                                width: selected ? 2 : 1.5,
                                              ),
                                              borderRadius: BorderRadius.circular(12),
                                              boxShadow: selected ? [
                                                BoxShadow(
                                                  color: Colors.purple.withOpacity(0.2),
                                                  blurRadius: 6,
                                                  offset: Offset(0, 1),
                                                ),
                                              ] : null,
                                            ),
                                            child: Row(
                                              children: [
                                                Container(
                                                  padding: EdgeInsets.all(6),
                                                  decoration: BoxDecoration(
                                                    color: selected 
                                                      ? habitColor.withOpacity(0.25)
                                                      : Colors.grey.shade200,
                                                    borderRadius: BorderRadius.circular(6),
                                                  ),
                                                  child: Icon(
                                                    iconData,
                                                    color: selected ? habitColor : Colors.grey.shade500,
                                                    size: 18,
                                                  ),
                                                ),
                                                SizedBox(width: 10),
                                                Expanded(
                                                  child: Text(
                                                    habit,
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight: selected 
                                                        ? FontWeight.w700 
                                                        : FontWeight.w500,
                                                      color: selected 
                                                        ? Colors.purple.shade600
                                                        : Colors.grey.shade700,
                                                    ),
                                                  ),
                                                ),
                                                if (selected) ...[
                                                  SizedBox(width: 6),
                                                  Icon(Icons.check, color: Colors.purple.shade600, size: 14),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),

                          SizedBox(height: 20),

                          // Activity Level Section
                          _buildFormSection(
                            title: "Activity Level",
                            icon: Icons.pets,
                            iconColor: Colors.green,
                            subtitle: "How active is your pet today?",
                            child: Column(
                              children: [
                                SizedBox(height: 12),
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    double itemWidth = (constraints.maxWidth - 12) / 2;
                                    return Wrap(
                                      spacing: 12,
                                      runSpacing: 12,
                                      children: activityLevels.map((level) {
                                    final selected = _activityLevel == level;
                                    IconData iconData;
                                    Color levelColor;
                                    
                                    switch(level) {
                                      case "High activity":
                                        iconData = Icons.flash_on;
                                        levelColor = Colors.green;
                                        break;
                                      case "Normal activity":
                                        iconData = Icons.wb_sunny_outlined;
                                        levelColor = Colors.blue;
                                        break;
                                      case "Low activity / lethargy":
                                        iconData = Icons.bedtime;
                                        levelColor = Colors.orange;
                                        break;
                                      case "Restlessness (especially at night)":
                                        iconData = Icons.pending_actions;
                                        levelColor = Colors.purple;
                                        break;
                                      case "Sudden weakness / collapse":
                                        iconData = Icons.warning_rounded;
                                        levelColor = Colors.red;
                                        break;
                                      default:
                                        iconData = Icons.circle_outlined;
                                        levelColor = Colors.grey;
                                    }
                                    
                                    return SizedBox(
                                      width: itemWidth,
                                      child: GestureDetector(
                                        onTap: () {
                                          setModalState(() => _activityLevel = level);
                                          setState(() => _activityLevel = level);
                                          HapticFeedback.lightImpact();
                                        },
                                        child: MouseRegion(
                                          cursor: SystemMouseCursors.click,
                                          child: AnimatedContainer(
                                            duration: Duration(milliseconds: 250),
                                            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                            decoration: BoxDecoration(
                                              color: selected 
                                                ? Colors.green.withOpacity(0.12) 
                                                : Colors.grey.shade50,
                                              border: Border.all(
                                                color: selected 
                                                  ? Colors.green.shade600
                                                  : Colors.grey.shade300,
                                                width: selected ? 2.5 : 1.5,
                                              ),
                                              borderRadius: BorderRadius.circular(12),
                                              boxShadow: selected ? [
                                                BoxShadow(
                                                  color: Colors.green.withOpacity(0.15),
                                                  blurRadius: 8,
                                                  offset: Offset(0, 2),
                                                ),
                                              ] : null,
                                            ),
                                            child: Row(
                                              children: [
                                                Container(
                                                  padding: EdgeInsets.all(8),
                                                  decoration: BoxDecoration(
                                                    color: selected 
                                                      ? levelColor.withOpacity(0.25)
                                                      : Colors.grey.shade200,
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  child: Icon(
                                                    iconData,
                                                    color: selected ? levelColor : Colors.grey.shade500,
                                                    size: 22,
                                                  ),
                                                ),
                                                SizedBox(width: 14),
                                                Expanded(
                                                  child: Text(
                                                    level,
                                                    style: TextStyle(
                                                      fontSize: 15,
                                                      fontWeight: selected 
                                                        ? FontWeight.w700 
                                                        : FontWeight.w500,
                                                      color: selected 
                                                        ? Colors.green.shade600
                                                        : Colors.grey.shade700,
                                                    ),
                                                  ),
                                                ),
                                                if (selected)
                                                  Container(
                                                    padding: EdgeInsets.all(4),
                                                    decoration: BoxDecoration(
                                                      color: Colors.green.shade600,
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
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),

                          SizedBox(height: 20),

                          // Clinical Signs Section
                          _buildFormSection(
                            title: "Clinical Signs",
                            icon: Icons.medical_services,
                            iconColor: Colors.red,
                            subtitle: "Check any physical clinical signs observed",
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(height: 12),
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    double itemWidth = (constraints.maxWidth - 12) / 2;
                                    return Wrap(
                                      spacing: 12,
                                      runSpacing: 12,
                                      children: commonSymptoms.map((clinicalSign) {
                                    final isSelected = _selectedSymptoms.contains(clinicalSign);
                                    final isNone = clinicalSign == "None of the Above";
                                    
                                    return SizedBox(
                                      width: itemWidth,
                                      child: Material(
                                        color: Colors.transparent,
                                        child: InkWell(
                                          onTap: () {
                                            // Update state only once to avoid duplicates
                                            if (isNone) {
                                              // If "None" is selected, clear all other clinical signs
                                              if (isSelected) {
                                                _selectedSymptoms.remove(clinicalSign);
                                              } else {
                                                _selectedSymptoms.clear();
                                                _selectedSymptoms.add(clinicalSign);
                                              }
                                            } else {
                                              // If any other clinical sign is selected, remove "None"
                                              if (isSelected) {
                                                _selectedSymptoms.remove(clinicalSign);
                                              } else {
                                                _selectedSymptoms.remove("None of the Above");
                                                _selectedSymptoms.add(clinicalSign);
                                              }
                                            }
                                            
                                            // Update both UI states after modification
                                            setModalState(() {});
                                            setState(() {});
                                            HapticFeedback.selectionClick();
                                          },
                                          borderRadius: BorderRadius.circular(10),
                                          child: AnimatedContainer(
                                            duration: Duration(milliseconds: 250),
                                            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                            decoration: BoxDecoration(
                                              color: isSelected 
                                                ? (isNone ? Colors.green.withOpacity(0.12) : Colors.red.withOpacity(0.12))
                                                : Colors.grey.shade50,
                                              border: Border.all(
                                                color: isSelected 
                                                  ? (isNone ? Colors.green.shade600 : Colors.red.shade600)
                                                  : Colors.grey.shade300,
                                                width: isSelected ? 2 : 1.5,
                                              ),
                                              borderRadius: BorderRadius.circular(10),
                                              boxShadow: isSelected ? [
                                                BoxShadow(
                                                  color: (isNone ? Colors.green : Colors.red).withOpacity(0.12),
                                                  blurRadius: 6,
                                                  offset: Offset(0, 1),
                                                ),
                                              ] : null,
                                            ),
                                            child: Row(
                                              children: [
                                                Container(
                                                  padding: EdgeInsets.all(4),
                                                  decoration: BoxDecoration(
                                                    color: isSelected 
                                                      ? (isNone ? Colors.green.shade200 : Colors.red.shade200)
                                                      : Colors.grey.shade200,
                                                    borderRadius: BorderRadius.circular(6),
                                                  ),
                                                  child: Icon(
                                                    isSelected 
                                                      ? Icons.check_box_rounded
                                                      : Icons.check_box_outline_blank_rounded,
                                                    color: isSelected 
                                                      ? (isNone ? Colors.green.shade700 : Colors.red.shade700)
                                                      : Colors.grey.shade500,
                                                    size: 20,
                                                  ),
                                                ),
                                                SizedBox(width: 10),
                                                Expanded(
                                                  child: Text(
                                                    clinicalSign,
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      fontWeight: isSelected 
                                                        ? FontWeight.w700 
                                                        : FontWeight.w500,
                                                      color: isSelected 
                                                        ? (isNone ? Colors.green.shade800 : Colors.red.shade800)
                                                        : Colors.grey.shade700,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                    );
                                  },
                                ),
                                if (_selectedSymptoms.isNotEmpty && !_selectedSymptoms.contains("None of the Above")) ...[
                                  SizedBox(height: 12),
                                  Container(
                                    padding: EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.orange.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: Colors.orange.withOpacity(0.4),
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700, size: 18),
                                        SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            "${_selectedSymptoms.where((s) => s != "None of the Above").length} clinical sign(s) detected. Consider consulting a vet if signs persist.",
                                            style: TextStyle(
                                              color: Colors.orange.shade900,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ] else if (_selectedSymptoms.isEmpty) ...[
                                  // Show requirement message if no symptoms selected
                                  SizedBox(height: 12),
                                  Container(
                                    padding: EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.red.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: Colors.red.withOpacity(0.4),
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Icon(Icons.error_outline, color: Colors.red.shade700, size: 18),
                                        SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            "Clinical signs are required. Select at least one option.",
                                            style: TextStyle(
                                              color: Colors.red.shade800,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                            ),
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
                            backgroundColor: _isFormValid() ? Colors.green : Colors.grey.shade300,
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
                            isEdit ? "Update Health Log" : "Save Health Log",
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          onPressed: !_isFormValid() ? null : () async {
                            try {
                              debugPrint('[SAVE_HEALTH_LOG] Button pressed - starting save process');
                              // Show loading state
                              setModalState(() {});
                              
                              final payload = {
                                'pet_id': _selectedPet!['id'],
                                'user_id': user?.id ?? '',
                                'log_date': DateFormat('yyyy-MM-dd').format(selectedDate),
                                'activity_level': _activityLevel,
                                // Health tracking fields - ONLY include columns that exist in the database schema
                                'food_intake': _foodIntake,
                                'water_intake': _waterIntake,
                                'bathroom_habits': _bathroomHabits,
                                'symptoms': json.encode(_selectedSymptoms), // Store as JSON string
                                // NOTE: 'notes', 'mood', 'body_temperature', 'appetite_behavior' columns do not exist in Supabase
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
                              await _fetchLatestHealthInsights(); // <-- refresh health insights with new data

                              // Show success feedback
                              if (mounted) {
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(
                                    content: Row(
                                      children: [
                                        Icon(Icons.check_circle, color: Colors.white),
                                        SizedBox(width: 8),
                                        Text(isEdit 
                                          ? 'Health log updated successfully!' 
                                          : 'Health data logged and analyzed!'),
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
    String? subtitle,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: iconColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: iconColor, size: 20),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.grey.shade800,
                          letterSpacing: 0.3,
                        ),
                      ),
                      if (subtitle != null) ...[
                        SizedBox(height: 3),
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  // Helper widget for sleep adjustment buttons
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
                                    ? DateFormat('MMM d, yyyy • hh:mm a').format(ts)
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