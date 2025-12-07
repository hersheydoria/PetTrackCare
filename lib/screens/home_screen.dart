import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:PetTrackCare/screens/chat_detail_screen.dart';
import 'package:PetTrackCare/services/notification_service.dart';
import '../services/auto_migration_service.dart';
import '../services/fastapi_service.dart';

const deepRed = Color(0xFFB82132);
const coral = Color(0xFFD2665A);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

class HomeScreen extends StatefulWidget {
  final String userId;

  HomeScreen({required this.userId});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  final _fastApi = FastApiService.instance;

  String userName = '';
  String userRole = '';
  List<dynamic> pets = [];
  List<dynamic> sittingJobs = [];
  List<dynamic> availableSitters = [];
  List<dynamic> ownerPendingRequests = [];
  List<dynamic> ownerActiveJobs = []; // track owner's active jobs
  Set<String> pendingSitterIds = {};
  Map<String, dynamic> summary = {};
  // NEW: sitter reviews and completed jobs count
  List<dynamic> sitterReviews = [];
  int completedJobsCount = 0;

  bool isLoading = true;

  // Add: sitter availability toggle state
  bool? _isSitterAvailable;
  bool _isUpdatingAvailability = false;

  // NEW: sitter profile data
  Map<String, dynamic>? _sitterProfile;
  bool _isLoadingProfile = false;

  // Add: jobs filter state
  String _jobsStatusFilter = 'Pending';
  static const List<String> _jobStatusOptions = ['All', 'Pending', 'Active', 'Completed'];

  late TabController _sitterTabController;
  
  // Search controller for location search
  final TextEditingController _locationSearchController = TextEditingController();
  String _currentSearchQuery = '';
  
  // Auto-migration service
  final AutoMigrationService _autoMigrationService = AutoMigrationService();

  @override
  void initState() {
    super.initState();
    fetchUserData();
    _sitterTabController = TabController(length: 3, vsync: this);
    
    // Trigger auto-migration when HomeScreen loads
    _runAutoMigrationInBackground();
  }
  
  /// Run auto-migration in background without blocking the UI
  void _runAutoMigrationInBackground() {
    // Use multiple logging methods to ensure visibility
    print('=== AUTO-MIGRATION TRIGGER FROM HOME_SCREEN ===');
    debugPrint('AUTO-MIGRATION TRIGGER CALLED FROM HomeScreen.initState()');
    print('Timestamp: ${DateTime.now().toIso8601String()}');
    print('User: ${widget.userId}');
    print('User Email: [hidden for security]');
    
    // Debug environment variables
    print('🔧 Environment Check:');
    print('   🔗 Firebase Host: ${dotenv.env['FIREBASE_HOST'] ?? "NOT SET"}');
    print('   🔑 Firebase Key: ${dotenv.env['FIREBASE_AUTH_KEY']?.substring(0, 10) ?? "NOT SET"}...[HIDDEN]');
    
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

  @override
  void dispose() {
    _sitterTabController.dispose();
    _locationSearchController.dispose();
    super.dispose();
  }

  // New: unified pull-to-refresh handler
  Future<void> _refreshAll() async {
    try {
      if (userRole == 'Pet Sitter') {
        await Future.wait([
          fetchSittingJobs(),
          fetchDailySummary(),
          fetchSitterProfile(), // NEW: refresh profile data
        ]);
      } else {
        await Future.wait([
          fetchOwnedPets(),          // will also update pending requests
          fetchAvailableSitters(locationQuery: _currentSearchQuery.isEmpty ? null : _currentSearchQuery),
          fetchDailySummary(),
          fetchOwnerPendingRequests(),
          fetchOwnerActiveJobs(), // added
        ]);
      }
    } catch (_) {}
  }

  Future<void> fetchUserData() async {
    try {
      final resolvedUser = Map<String, dynamic>.from(await _fastApi.fetchUserById(widget.userId));

      setState(() {
        userRole = (resolvedUser['role'] as String?) ?? 'Pet Owner';
        userName = (resolvedUser['name'] ?? resolvedUser['email'] ?? 'PetTrackCare').toString();
      });

      await Future.wait([
        if (userRole == 'Pet Sitter') fetchSittingJobs(),
        if (userRole == 'Pet Sitter') fetchSitterReviews(),
        if (userRole == 'Pet Sitter') fetchSitterAvailability(), // NEW: load availability
        if (userRole == 'Pet Sitter') fetchSitterProfile(), // NEW: load profile
        if (userRole == 'Pet Owner') fetchOwnedPets(),
        if (userRole == 'Pet Owner') fetchAvailableSitters(),
        if (userRole == 'Pet Owner') fetchOwnerActiveJobs(), // automatically load active jobs
        fetchDailySummary()
      ]);

      setState(() => isLoading = false);
    } catch (e) {
      print('❌ fetchUserData ERROR: $e');
      setState(() => isLoading = false);
    }
  }

  Future<void> fetchAvailableSitters({String? locationQuery}) async {
    try {
      final rows = await _fastApi.fetchSitters(
        locationQuery: locationQuery,
        limit: 50,
        offset: 0,
      );
      if (mounted) {
        if (locationQuery != null && locationQuery.trim().isNotEmpty) {
          final trimmed = locationQuery.trim();
          if (rows.isEmpty) {
            _showEnhancedSnackBar('No sitters found in "$trimmed". Showing all available sitters.');
          } else {
            _showEnhancedSnackBar('Found ${rows.length} sitter(s) in "$trimmed"');
          }
        }
      }
      setState(() => availableSitters = rows);
    } catch (e) {
      print('❌ fetchAvailableSitters ERROR: $e');
      if (mounted) {
        _showEnhancedSnackBar('Error loading sitters. Please try again.', isError: true);
      }
    }
  }

  Future<void> fetchOwnedPets() async {
    try {
      final petRes = await _fastApi.fetchPets(ownerId: widget.userId);
      setState(() => pets = petRes);
    } catch (backendError) {
      print('⚠️ FastAPI fetchPets failed: $backendError');
      if (mounted) {
        _showEnhancedSnackBar('Failed to load pets.', isError: true);
      }
    }
    // After we have the owner's pets, fetch any pending sitting requests they created
    await fetchOwnerPendingRequests();
    // Also fetch active jobs for the owner
    await fetchOwnerActiveJobs();
  }

  Future<void> fetchOwnerPendingRequests() async {
    if (pets.isEmpty) {
      setState(() {
        ownerPendingRequests = [];
        pendingSitterIds = {};
      });
      return;
    }

    try {
      final rows = await _fastApi.fetchOwnerJobs(ownerId: widget.userId, status: 'Pending');
      setState(() {
        ownerPendingRequests = rows;
        pendingSitterIds = rows
            .map((r) => r['sitter_id'])
            .where((id) => id != null && id.toString().isNotEmpty)
            .map<String>((id) => id.toString())
            .toSet();
      });
    } catch (e) {
      print('❌ fetchOwnerPendingRequests ERROR: $e');
    }
  }

  Future<void> fetchSittingJobs() async {
    try {
      final jobsRes = await _fastApi.fetchSittingJobsForSitter(widget.userId);
      final completed = jobsRes
          .where((j) => (j['status'] ?? '').toString().toLowerCase() == 'completed')
          .length;
      setState(() {
        sittingJobs = jobsRes;
        completedJobsCount = completed;
      });
    } catch (e) {
      print('❌ fetchSittingJobs ERROR: $e');
      if (mounted) {
        _showEnhancedSnackBar('Failed to load jobs.', isError: true);
      }
    }
  }

  // NEW: fetch latest sitter reviews
  Future<void> fetchSitterReviews() async {
    try {
      final res = await _fastApi.fetchSitterReviews(widget.userId);
      setState(() => sitterReviews = res);
    } catch (e) {
      print('❌ fetchSitterReviews ERROR: $e');
      setState(() => sitterReviews = []);
    }
  }

  Future<void> fetchDailySummary() async {
    try {
      final summaryRes = await _fastApi.fetchLatestBehaviorLog(widget.userId);
      setState(() => summary = summaryRes);
    } catch (e) {
      print('❌ fetchDailySummary ERROR: $e');
      setState(() => summary = {});
    }
  }

  // Fetch reviews for a sitter by their users.id (resolves to sitters.id, with join fallback)
  Future<List<dynamic>> _fetchReviewsForSitterUser(String sitterUserId) async {
    try {
      return await _fastApi.fetchSitterReviews(sitterUserId);
    } catch (e) {
      print('❌ _fetchReviewsForSitterUser ERROR: $e');
      return [];
    }
  }

  // Show a modal bottom sheet with the sitter's reviews
  Future<void> _showSitterReviewsModal(Map<String, dynamic> sitter) async {
    final sitterUserId = sitter['id']?.toString();
    if (sitterUserId == null || sitterUserId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Invalid sitter id.'),
          backgroundColor: deepRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.8,
          decoration: BoxDecoration(
            color: lightBlush,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // Enhanced header with gradient
              Container(
                width: double.infinity,
                padding: EdgeInsets.fromLTRB(20, 16, 20, 20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [deepRed, coral],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: Column(
                  children: [
                    // Handle bar
                    Container(
                      height: 4,
                      width: 40,
                      margin: EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    // Header content
                    Row(
                      children: [
                        Container(
                          padding: EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.rate_review,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Reviews',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: Colors.white70,
                                  fontFamily: 'Roboto',
                                ),
                              ),
                              Text(
                                sitter['name'] ?? 'Sitter',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  fontFamily: 'Roboto',
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
              // Content area
              Expanded(
                child: Container(
                  padding: EdgeInsets.all(20),
                  child: FutureBuilder<List<dynamic>>(
                    future: _fetchReviewsForSitterUser(sitterUserId),
                    builder: (context, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 60,
                                height: 60,
                                padding: EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: coral.withOpacity(0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: CircularProgressIndicator(
                                  color: deepRed,
                                  strokeWidth: 3,
                                ),
                              ),
                              SizedBox(height: 16),
                              Text(
                                'Loading reviews...',
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontFamily: 'Roboto',
                                ),
                              ),
                            ],
                          ),
                        );
                      }
                      final items = snap.data ?? [];
                      if (items.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 80,
                                height: 80,
                                decoration: BoxDecoration(
                                  color: coral.withOpacity(0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.reviews_outlined,
                                  size: 40,
                                  color: coral,
                                ),
                              ),
                              SizedBox(height: 16),
                              Text(
                                'No Reviews Yet',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: deepRed,
                                  fontFamily: 'Roboto',
                                ),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'This sitter hasn\'t received any reviews yet.',
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontFamily: 'Roboto',
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        );
                      }
                      return ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, __) => SizedBox(height: 16),
                        itemBuilder: (_, i) => _buildEnhancedReviewCard(items[i] as Map<String, dynamic>),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Update job status: return updated row (if allowed) and patch UI safely
  Future<void> _updateJobStatus(String jobId, String status) async {
    final update = <String, dynamic>{'status': status};
    if (status == 'Active') {
      update['start_date'] = DateTime.now().toIso8601String().substring(0, 10);
    }
    if (status == 'Completed') {
      update['end_date'] = DateTime.now().toIso8601String().substring(0, 10);
    }

    try {
      final jobResponse = Map<String, dynamic>.from(await _fastApi.updateSittingJob(jobId, update));
      final petName = jobResponse['pet_name']?.toString() ?? 'Pet';
      final ownerId = jobResponse['owner_id']?.toString();
      final sitterId = jobResponse['sitter_id']?.toString();
      final actorName = userName.isNotEmpty
          ? userName
          : (userRole.isNotEmpty ? userRole : 'PetTrackCare');

      String? notificationRecipient;
      String? notificationType;
      if (status == 'Active') {
        notificationRecipient = ownerId;
        notificationType = 'job_accepted';
      } else if (status == 'Cancelled') {
        notificationRecipient = widget.userId == ownerId ? sitterId : ownerId;
        notificationType = 'job_declined';
      } else if (status == 'Completed') {
        notificationRecipient = sitterId;
        notificationType = 'job_completed';
      }

      if (notificationRecipient != null && notificationRecipient != widget.userId && notificationType != null) {
        try {
          await sendJobNotification(
            recipientId: notificationRecipient,
            actorId: widget.userId,
            jobId: jobId,
            type: notificationType,
            petName: petName,
            actorName: actorName,
          );
        } catch (notificationError) {
          print('⚠️ Notification failed: $notificationError');
        }
      }

      setState(() {
        final idx = sittingJobs.indexWhere((j) => j['id']?.toString() == jobId);
        if (idx != -1) {
          if (status == 'Cancelled') {
            sittingJobs.removeAt(idx);
          } else {
            sittingJobs[idx] = jobResponse;
          }
        } else if (status != 'Cancelled') {
          sittingJobs.add(jobResponse);
        }
        completedJobsCount = sittingJobs
            .where((j) => (j['status'] ?? '').toString().toLowerCase() == 'completed')
            .length;
      });

      Future.wait([
        fetchSittingJobs(),
        fetchOwnerPendingRequests(),
        fetchOwnerActiveJobs(),
      ]).catchError((e) {
        print('⚠️ Background refresh error: $e');
        return [];
      });

      if (mounted) {
        _showEnhancedSnackBar('Job $status.');
      }
    } catch (e) {
      if (mounted) {
        _showEnhancedSnackBar('Failed to update job: $e', isError: true);
      }
    }
  }

  // Open chat with owner
  void _openChatWithOwner(String ownerId, {String? ownerName}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatDetailScreen(
          userId: widget.userId,
          receiverId: ownerId,
          userName: ownerName ?? 'Owner',
        ),
      ),
    );
  }

  // Get pets that are not currently assigned to any active sitting job
  Future<List<Map<String, dynamic>>> _getAvailablePetsForHiring() async {
    try {
      final activeJobs = await _fastApi.fetchOwnerJobs(ownerId: widget.userId, status: 'Active');
      final pendingJobs = await _fastApi.fetchOwnerJobs(ownerId: widget.userId, status: 'Pending');
      final assignedPetIds = [
        ...activeJobs,
        ...pendingJobs,
      ]
          .map((job) => job['pet_id']?.toString())
          .where((id) => id != null && id.isNotEmpty)
          .cast<String>()
          .toSet();

      return pets
          .where((pet) {
            final petId = pet['id']?.toString();
            return petId != null && !assignedPetIds.contains(petId);
          })
          .map((pet) => Map<String, dynamic>.from(pet as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('❌ _getAvailablePetsForHiring ERROR: $e');
      return [];
    }
  }

  // Enhanced Hire modal with modern design
  Future<void> _showHireModal(Map<String, dynamic> sitter) async {
    if (pets.isEmpty) {
      _showEnhancedSnackBar('You have no pets. Add a pet before hiring a sitter.', isError: true);
      return;
    }

    // Get pets that are not currently assigned to any active job
    final availablePets = await _getAvailablePetsForHiring();
    
    if (availablePets.isEmpty) {
      _showEnhancedSnackBar('All your pets are currently assigned to sitters.', isError: true);
      return;
    }

    String? selectedPetId = availablePets.isNotEmpty ? availablePets.first['id'] as String? : null;
    Map<String, dynamic>? findPetById(String? id) {
      if (id == null) return null;
      for (final pet in availablePets) {
        if (pet['id'] == id) {
          return pet;
        }
      }
      return null;
    }
    Map<String, dynamic>? selectedPet = findPetById(selectedPetId);
    final sitterProfilePicture = sitter['profile_picture']?.toString();
    final sitterName = sitter['name']?.toString() ?? 'Sitter';

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
          return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.6,
              decoration: BoxDecoration(
                color: lightBlush,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                children: [
                  // Enhanced header
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.fromLTRB(20, 16, 20, 20),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [deepRed, coral],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                    ),
                    child: Column(
                      children: [
                        // Handle bar
                        Container(
                          height: 4,
                          width: 40,
                          margin: EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        // Header content
                        Row(
                          children: [
                            _buildCircularAvatar(
                              name: sitterName,
                              imageUrl: sitterProfilePicture,
                              size: 52,
                              borderColor: Colors.white70,
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Hire Sitter',
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Colors.white70,
                                      fontFamily: 'Roboto',
                                    ),
                                  ),
                                  Text(
                                    sitterName,
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                      fontFamily: 'Roboto',
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
                  // Content area
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Sitter info card
                            Container(
                              padding: EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: coral.withOpacity(0.2)),
                                boxShadow: [
                                  BoxShadow(
                                    color: deepRed.withOpacity(0.08),
                                    blurRadius: 8,
                                    offset: Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: Row(
                                children: [
                                  _buildCircularAvatar(
                                    name: sitterName,
                                    imageUrl: sitterProfilePicture,
                                    size: 50,
                                    borderColor: Colors.grey.withOpacity(0.3),
                                  ),
                                  SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          sitterName,
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: deepRed,
                                            fontFamily: 'Roboto',
                                          ),
                                        ),
                                        if (sitter['rate_per_hour'] != null)
                                          Text(
                                            '₱${sitter['rate_per_hour']}/hour',
                                            style: TextStyle(
                                              fontSize: 14,
                                              color: Colors.green[700],
                                              fontWeight: FontWeight.w600,
                                              fontFamily: 'Roboto',
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(height: 20),
                            
                            // Pet selection
                            Text(
                              'Select Pet to Care For',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: deepRed,
                                fontFamily: 'Roboto',
                              ),
                            ),
                            SizedBox(height: 8),
                            if (selectedPet != null) ...[ 
                              () {
                                final petPreview = selectedPet!;
                                return Row(
                                  children: [
                                    _buildPetProfileAvatar(
                                      profilePicture: petPreview['profile_picture']?.toString(),
                                      size: 36,
                                    ),
                                    SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            petPreview['name']?.toString() ?? 'Selected pet',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: deepRed,
                                              fontFamily: 'Roboto',
                                            ),
                                          ),
                                          Text(
                                            'This pet is ready for a sitter',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey[600],
                                              fontFamily: 'Roboto',
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                );
                              }(),
                              SizedBox(height: 12),
                            ],
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: coral.withOpacity(0.3)),
                              ),
                              child: DropdownButtonFormField<String>(
                                value: selectedPetId,
                                items: availablePets.map<DropdownMenuItem<String>>((p) {
                                  return DropdownMenuItem(
                                    value: p['id'] as String?,
                                    child: Row(
                                      children: [
                                        _buildPetProfileAvatar(
                                          profilePicture: p['profile_picture']?.toString(),
                                          size: 30,
                                        ),
                                        SizedBox(width: 8),
                                        Text(
                                          p['name'] ?? 'Unnamed',
                                          style: TextStyle(fontFamily: 'Roboto'),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                                onChanged: (v) => setModalState(() {
                                  selectedPetId = v;
                                  selectedPet = findPetById(v);
                                }),
                                decoration: InputDecoration(
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  hintText: 'Choose a pet...',
                                ),
                              ),
                            ),
                            SizedBox(height: 30),
                            
                            // Action buttons
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () => Navigator.of(context).pop(),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.red,
                                      side: BorderSide(color: Colors.red),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      padding: EdgeInsets.symmetric(vertical: 16),
                                    ),
                                    child: Text(
                                      'Cancel',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontFamily: 'Roboto',
                                        color: Colors.red,
                                      ),
                                    ),
                                  ),
                                ),
                                SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () async {
                                      if (selectedPetId == null) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text('Please select a pet.'),
                                            backgroundColor: deepRed,
                                            behavior: SnackBarBehavior.floating,
                                          ),
                                        );
                                        return;
                                      }
                                      Navigator.of(context).pop();
                                      await _createSittingJob(sitter['id'] as String, selectedPetId!);
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.green,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      padding: EdgeInsets.symmetric(vertical: 16),
                                      elevation: 2,
                                    ),
                                    child: Text(
                                      'Confirm Hire',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontFamily: 'Roboto',
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
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

  // Create a pending job (start_date provisional; overwritten on accept)
  Future<void> _createSittingJob(String sitterId, String petId) async {
    try {
      final payload = {
        'sitter_id': sitterId,
        'pet_id': petId,
        'start_date': DateTime.now().toIso8601String().substring(0, 10), // will be set again on accept
        'end_date': null,
        'status': 'Pending',
      };
      final response = await _fastApi.createSittingJob(payload);
      final jobId = response['id']?.toString();
      final petData = pets.firstWhere(
        (p) => p['id'] == petId,
        orElse: () => <String, dynamic>{},
      );
      final petName = petData['name']?.toString() ?? 'Pet';
      final ownerName = (userName.isEmpty ? 'Pet Owner' : userName);
      
      // Try to send notification (fire and forget)
      if (jobId != null) {
        try {
          await sendJobNotification(
            recipientId: sitterId,
            actorId: widget.userId,
            jobId: jobId,
            type: 'job_request',
            petName: petName,
            actorName: ownerName,
          );
        } catch (notifError) {
          print('⚠️ Failed to send job notification: $notifError');
        }
      }
      
      setState(() {
        pendingSitterIds.add(sitterId);
      });
      _showEnhancedSnackBar('Sitter hired — request sent.');
      
      // Refresh background (fire and forget)
      Future.wait([fetchOwnerPendingRequests(), fetchOwnerActiveJobs()]).catchError((e) {
        print('⚠️ Background refresh error: $e');
        return [];
      });
    } catch (e) {
      print('❌ createSittingJob ERROR: $e');
      _showEnhancedSnackBar('Failed to create sitting job.', isError: true);
    }
  }

  // Fetch owner's Active jobs (for "Mark Finished")
  Future<void> fetchOwnerActiveJobs() async {
    try {
      if (pets.isEmpty) {
        setState(() => ownerActiveJobs = []);
        return;
      }
      final rows = await _fastApi.fetchOwnerJobs(ownerId: widget.userId, status: 'Active');
      setState(() => ownerActiveJobs = rows);
    } catch (e) {
      print('❌ fetchOwnerActiveJobs ERROR: $e');
    }
  }

  // Enhanced modal for owners to finish job and add review of sitter
  Future<void> _showFinishJobModal(Map<String, dynamic> job) async {
    double rating = 5;
    String comment = '';
    final petName = (job['pets']?['name'] ?? job['pet_id'] ?? 'Pet').toString();
    
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Container(
              height: MediaQuery.of(ctx).size.height * 0.75,
              decoration: BoxDecoration(
                color: lightBlush,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                children: [
                  // Enhanced header
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.fromLTRB(20, 16, 20, 20),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [deepRed, coral],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                    ),
                    child: Column(
                      children: [
                        // Handle bar
                        Container(
                          height: 4,
                          width: 40,
                          margin: EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        // Header content
                        Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.task_alt,
                                color: Colors.white,
                                size: 24,
                              ),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Complete Job',
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Colors.white70,
                                      fontFamily: 'Roboto',
                                    ),
                                  ),
                                  Text(
                                    'Job for $petName',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                      fontFamily: 'Roboto',
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
                  // Content area
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Rating section
                            Container(
                              padding: EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: coral.withOpacity(0.2)),
                                boxShadow: [
                                  BoxShadow(
                                    color: deepRed.withOpacity(0.08),
                                    blurRadius: 8,
                                    offset: Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.star,
                                        color: coral,
                                        size: 20,
                                      ),
                                      SizedBox(width: 8),
                                      Text(
                                        'Rate the sitter',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: deepRed,
                                          fontFamily: 'Roboto',
                                        ),
                                      ),
                                    ],
                                  ),
                                  SizedBox(height: 16),
                                  // Star rating display
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: List.generate(5, (index) {
                                      return GestureDetector(
                                        onTap: () => setModalState(() => rating = index + 1.0),
                                        child: Container(
                                          padding: EdgeInsets.all(4),
                                          child: Icon(
                                            index < rating ? Icons.star : Icons.star_border,
                                            size: 32,
                                            color: coral,
                                          ),
                                        ),
                                      );
                                    }),
                                  ),
                                  SizedBox(height: 8),
                                  Text(
                                    'Rating: ${rating.toInt()}/5',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: deepRed,
                                      fontFamily: 'Roboto',
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(height: 20),
                            // Comment section
                            Container(
                              padding: EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: coral.withOpacity(0.2)),
                                boxShadow: [
                                  BoxShadow(
                                    color: deepRed.withOpacity(0.08),
                                    blurRadius: 8,
                                    offset: Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.edit,
                                        color: coral,
                                        size: 20,
                                      ),
                                      SizedBox(width: 8),
                                      Text(
                                        'Add Review (Optional)',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: deepRed,
                                          fontFamily: 'Roboto',
                                        ),
                                      ),
                                    ],
                                  ),
                                  SizedBox(height: 16),
                                  TextField(
                                    maxLines: 4,
                                    decoration: InputDecoration(
                                      hintText: 'Share your experience with this sitter...',
                                      hintStyle: TextStyle(
                                        color: Colors.grey[400],
                                        fontFamily: 'Roboto',
                                      ),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: BorderSide(color: coral.withOpacity(0.3)),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: BorderSide(color: coral),
                                      ),
                                      filled: true,
                                      fillColor: lightBlush.withOpacity(0.1),
                                    ),
                                    style: TextStyle(
                                      fontFamily: 'Roboto',
                                      fontSize: 14,
                                    ),
                                    onChanged: (value) => comment = value,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
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
                          offset: Offset(0, -2),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: Colors.red),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: EdgeInsets.symmetric(vertical: 16),
                            ),
                            child: Text(
                              'Cancel',
                              style: TextStyle(
                                color: Colors.red,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Roboto',
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: EdgeInsets.symmetric(vertical: 16),
                              elevation: 2,
                            ),
                            onPressed: () async {
                              Navigator.of(ctx).pop();
                              try {
                                // 1) complete job
                                await _updateJobStatus(job['id'].toString(), 'Completed');

                                final sitterUserId = job['sitter_id']?.toString();
                                if (sitterUserId == null) {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Cannot post review: sitter profile not found.'),
                                        backgroundColor: deepRed,
                                        behavior: SnackBarBehavior.floating,
                                      ),
                                    );
                                  }
                                  return;
                                }

                                await _fastApi.createSitterReview(
                                  sitterUserId,
                                  {
                                    'rating': rating.round(),
                                    'comment': comment.trim().isEmpty ? null : comment.trim(),
                                    'owner_name': (userName.isEmpty ? 'Pet Owner' : userName),
                                  },
                                );

                                // Optional: refresh reviews (useful if current user is the sitter)
                                await fetchSitterReviews();

                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Job completed and review posted successfully!'),
                                      backgroundColor: Colors.green,
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              } catch (e) {
                                // Show detailed error for easier debugging (e.g., FK violations, privileges)
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Failed to complete job: $e'),
                                      backgroundColor: deepRed,
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                                print('❌ Review insert failed: $e');
                              }
                            },
                            child: Text(
                              'Complete & Review',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Roboto',
                              ),
                            ),
                          ),
                        ),
                      ],
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

  // New: Greeting header with gradient and time-aware salutation
  Widget _buildSitterGreeting() {
    final hour = DateTime.now().hour;
    final salutation = hour < 12
        ? 'Good morning'
        : hour < 17
            ? 'Good afternoon'
            : 'Good evening';

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [deepRed, coral]),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 3))],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.pets, color: Colors.white, size: 24),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$salutation, $userName',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                    fontFamily: 'Roboto',
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  "Your sitter dashboard is ready.",
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 14,
                    fontFamily: 'Roboto',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Owner: Greeting header with gradient and time-aware salutation
  Widget _buildOwnerGreeting() {
    final hour = DateTime.now().hour;
    final salutation = hour < 12
        ? 'Good morning'
        : hour < 17
            ? 'Good afternoon'
            : 'Good evening';

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [deepRed, coral]),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 3))],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.pets, color: Colors.white, size: 24),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$salutation, $userName',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                    fontFamily: 'Roboto',
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  "Find trusted sitters and manage your requests.",
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 14,
                    fontFamily: 'Roboto',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Enhanced owner dashboard with modern card design
  Widget _buildEnhancedOwnerDashboard() {
    final petsCount = pets.length;
    final pendingCount = ownerPendingRequests.length;
    final availableNow = availableSitters.where((s) => (s['is_available'] == true)).length;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.white, lightBlush.withOpacity(0.3)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: coral.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 8,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with icon - Enhanced
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [deepRed, coral]),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: deepRed.withOpacity(0.3),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(Icons.dashboard, color: Colors.white, size: 26),
              ),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Dashboard Overview',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: deepRed,
                        fontFamily: 'Roboto',
                      ),
                    ),
                    Text(
                      'Your pet care summary',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w500,
                        fontFamily: 'Roboto',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          
          SizedBox(height: 20),
          
          // Dashboard metrics with enhanced styling
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: _buildOwnerMetricCard(
                  icon: Icons.pets,
                  title: 'My Pets',
                  value: petsCount.toString(),
                  subtitle: 'Registered',
                  color: deepRed,
                ),
              ),
              SizedBox(width: 14),
              Expanded(
                child: _buildOwnerMetricCard(
                  icon: Icons.pending_actions,
                  title: 'Pending',
                  value: pendingCount.toString(),
                  subtitle: 'Requests',
                  color: Colors.orange[600]!,
                ),
              ),
              SizedBox(width: 14),
              Expanded(
                child: _buildOwnerMetricCard(
                  icon: Icons.groups,
                  title: 'Available',
                  value: availableNow.toString(),
                  subtitle: 'Sitters online',
                  color: Colors.green[600]!,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Enhanced active jobs section for owners
  Widget _buildEnhancedOwnerActiveJobsSection() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.white, lightBlush.withOpacity(0.2)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: coral.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 8,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [Colors.green, Colors.green.shade400]),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.work, color: Colors.white, size: 20),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Active Jobs',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: deepRed,
                        fontFamily: 'Roboto',
                      ),
                    ),
                    Text(
                      'Track your ongoing pet sitting services',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                        fontFamily: 'Roboto',
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.green.withOpacity(0.3)),
                ),
                child: Text(
                  '${ownerActiveJobs.length}',
                  style: TextStyle(
                    color: Colors.green,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'Roboto',
                  ),
                ),
              ),
            ],
          ),

          SizedBox(height: 16),

          // Jobs list
          if (ownerActiveJobs.isEmpty)
            _buildEmptyActiveJobsState()
          else
            Column(
              children: ownerActiveJobs.map((job) => _buildEnhancedOwnerJobCard(job)).toList(),
            ),
        ],
      ),
    );
  }

  // Enhanced sitter discovery section
  Widget _buildEnhancedSitterDiscoverySection() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.white, coral.withOpacity(0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: coral.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 8,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [coral, peach]),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.search, color: Colors.white, size: 20),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Find Pet Sitters',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: deepRed,
                        fontFamily: 'Roboto',
                      ),
                    ),
                    Text(
                      'Discover trusted caregivers in your area',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                        fontFamily: 'Roboto',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          SizedBox(height: 16),

          // Search bar
          TextField(
            controller: _locationSearchController,
            decoration: InputDecoration(
              hintText: 'Search Sitters by Location',
              hintStyle: TextStyle(
                fontFamily: 'Roboto',
                color: Colors.grey[600],
              ),
              prefixIcon: Icon(Icons.search, color: coral),
              suffixIcon: _currentSearchQuery.isNotEmpty 
                  ? IconButton(
                      icon: Icon(Icons.clear, color: coral),
                      onPressed: _clearSearch,
                    )
                  : null,
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: coral.withOpacity(0.3)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: coral.withOpacity(0.3)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: coral, width: 2),
              ),
            ),
            onSubmitted: _performSearch,
            onChanged: (value) {
              if (value.isEmpty && _currentSearchQuery.isNotEmpty) {
                _clearSearch();
              }
            },
          ),

          SizedBox(height: 16),

          // Sitter tabs
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Column(
              children: [
                TabBar(
                  controller: _sitterTabController,
                  indicatorColor: deepRed,
                  labelColor: deepRed,
                  unselectedLabelColor: Colors.grey,
                  labelStyle: TextStyle(fontFamily: 'Roboto', fontWeight: FontWeight.w600),
                  unselectedLabelStyle: TextStyle(fontFamily: 'Roboto'),
                  tabs: [
                    Tab(text: 'All Sitters'),
                    Tab(text: 'Available Now'),
                    Tab(text: 'Top Rated'),
                  ],
                ),
                Divider(height: 1, color: Colors.grey.shade300),
                SizedBox(
                  height: 600,
                  child: TabBarView(
                    controller: _sitterTabController,
                    children: [
                      _buildSitterList(availableSitters),
                      _buildSitterList(
                        availableSitters.where((s) => s['is_available'] == true).toList(),
                      ),
                      _buildSitterList(
                        availableSitters.where((s) {
                          final r = s['rating'];
                          return r is num && r >= 4.5;
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Helper methods for enhanced owner UI

  // Owner metric card helper - Enhanced
  Widget _buildOwnerMetricCard({
    required IconData icon,
    required String title,
    required String value,
    required String subtitle,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 18, horizontal: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.white, color.withOpacity(0.08)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.25), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.12),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: color.withOpacity(0.2), width: 1),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          SizedBox(height: 10),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: color,
              fontFamily: 'Roboto',
            ),
          ),
          SizedBox(height: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
              letterSpacing: 0.3,
              fontFamily: 'Roboto',
            ),
          ),
          SizedBox(height: 3),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey[600],
              fontWeight: FontWeight.w500,
              fontFamily: 'Roboto',
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildPetProfileAvatar({String? profilePicture, double size = 40}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: profilePicture != null && profilePicture.isNotEmpty
            ? Image.network(
                profilePicture,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    color: coral.withOpacity(0.1),
                    child: Icon(Icons.pets, color: coral, size: size * 0.5),
                  );
                },
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return Container(
                    color: Colors.grey.shade100,
                    child: Center(
                      child: CircularProgressIndicator(
                        value: loadingProgress.expectedTotalBytes != null
                            ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                            : null,
                        color: coral,
                        strokeWidth: 2,
                      ),
                    ),
                  );
                },
              )
            : Container(
                color: coral.withOpacity(0.1),
                child: Icon(Icons.pets, color: coral, size: size * 0.5),
              ),
      ),
    );
  }

  Widget _buildDefaultSitterAvatar(String name) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [coral.withOpacity(0.8), deepRed.withOpacity(0.8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : 'S',
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.bold,
            fontFamily: 'Roboto',
          ),
        ),
      ),
    );
  }

  // Enhanced owner job card
  Widget _buildEnhancedOwnerJobCard(Map<String, dynamic> job) {
    final petName = (job['pet_name'] ?? 'Pet').toString();
    final petProfilePicture = job['pet_profile_picture']?.toString() ?? '';
    final startDate = (job['start_date'] ?? '').toString();
    
    // Get sitter information
    final sitterName = (job['sitter_name'] ?? 'Sitter').toString();
    final sitterProfilePicture = job['sitter_profile_picture']?.toString() ?? '';
    
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Pet and Sitter Info Row
          Row(
            children: [
              // Pet Info
              _buildPetProfileAvatar(profilePicture: petProfilePicture, size: 44),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pet: $petName',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: deepRed,
                        fontSize: 16,
                        fontFamily: 'Roboto',
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Started: ${startDate.isEmpty ? 'Not specified' : startDate}',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 14,
                        fontFamily: 'Roboto',
                      ),
                    ),
                  ],
                ),
              ),
              // Sitter Info
              Column(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: coral.withOpacity(0.3)),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: sitterProfilePicture != null && sitterProfilePicture.isNotEmpty
                          ? Image.network(
                              sitterProfilePicture,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) => _buildDefaultSitterAvatar(sitterName),
                            )
                          : _buildDefaultSitterAvatar(sitterName),
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    sitterName,
                    style: TextStyle(
                      color: coral,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'Roboto',
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ],
          ),
          SizedBox(height: 16),
          // Mark Finished button for owners
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Colors.green, Colors.green.shade600]),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ElevatedButton(
              onPressed: () => _showFinishJobModal(job),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                foregroundColor: Colors.white,
                shadowColor: Colors.transparent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(
                'Mark Finished',
                style: TextStyle(
                  fontFamily: 'Roboto',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Empty active jobs state
  Widget _buildEmptyActiveJobsState() {
    return Container(
      padding: EdgeInsets.all(32),
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.grey.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.work_off,
              size: 48,
              color: Colors.grey,
            ),
          ),
          SizedBox(height: 16),
          Text(
            'No Active Jobs',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.grey[700],
              fontFamily: 'Roboto',
            ),
          ),
          SizedBox(height: 8),
          Text(
            'You don\'t have any active pet sitting jobs at the moment.',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[600],
              fontFamily: 'Roboto',
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildOwnerHome() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Enhanced greeting and summary for owners
        _buildOwnerGreeting(),
        SizedBox(height: 24),

        // Enhanced: Owner dashboard cards with modern design
        _buildEnhancedOwnerDashboard(),

        SizedBox(height: 16),

        // Enhanced: Active Jobs section with modern design
        _buildEnhancedOwnerActiveJobsSection(),

        SizedBox(height: 16),

        // Enhanced: Sitter search and discovery section
        _buildEnhancedSitterDiscoverySection(),
      ],
    );
  }

  // Enhanced sitter list with modern card design
  Widget _buildSitterList(List<dynamic> sitters) {
    if (sitters.isEmpty) {
      return _buildEmptyState(
        icon: Icons.person_search,
        title: 'No Sitters Found',
        subtitle: 'Try adjusting your search or check back later',
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshAll,
      color: deepRed,
      backgroundColor: Colors.white,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.all(12),
        itemCount: sitters.length,
        itemBuilder: (context, index) {
          final sitter = sitters[index];
          final num? ratingNum = sitter['rating'] == null ? null : (sitter['rating'] as num);
          final bool isAvail = sitter['is_available'] == true;
          final dynamic rateVal = sitter['rate_per_hour'];
          final String? profilePic = sitter['profile_picture'];

          return Container(
            margin: EdgeInsets.only(bottom: 16),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _showSitterReviewsModal(sitter),
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isAvail ? coral.withOpacity(0.3) : Colors.grey.shade300,
                      width: isAvail ? 2 : 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: isAvail 
                          ? deepRed.withOpacity(0.1) 
                          : Colors.grey.withOpacity(0.08),
                        blurRadius: isAvail ? 12 : 8,
                        offset: Offset(0, isAvail ? 4 : 2),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Enhanced avatar with status indicator
                          Stack(
                            children: [
                              Container(
                                width: 60,
                                height: 60,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: isAvail ? coral : Colors.grey.shade300,
                                    width: 3,
                                  ),
                                ),
                                child: ClipOval(
                                  child: profilePic != null && profilePic.isNotEmpty
                                      ? Image.network(
                                          profilePic,
                                          width: 54,
                                          height: 54,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) => _buildDefaultAvatar(sitter['name'] ?? 'S'),
                                        )
                                      : _buildDefaultAvatar(sitter['name'] ?? 'S'),
                                ),
                              ),
                              // Availability indicator
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: Container(
                                  width: 18,
                                  height: 18,
                                  decoration: BoxDecoration(
                                    color: isAvail ? Colors.green : Colors.grey,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 2),
                                  ),
                                  child: Icon(
                                    isAvail ? Icons.check : Icons.schedule,
                                    color: Colors.white,
                                    size: 10,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Name and status
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        sitter['name'] ?? 'Unnamed',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: deepRed,
                                          fontFamily: 'Roboto',
                                        ),
                                      ),
                                    ),
                                    Container(
                                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: isAvail ? Colors.green.withOpacity(0.1) : Colors.grey.withOpacity(0.1),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: isAvail ? Colors.green : Colors.grey,
                                          width: 1,
                                        ),
                                      ),
                                      child: Text(
                                        isAvail ? 'Available' : 'Busy',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: isAvail ? Colors.green[700] : Colors.grey[700],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                SizedBox(height: 8),
                                // Rating
                                if (ratingNum != null) ...[
                                  Row(
                                    children: [
                                      ..._buildRatingStars(ratingNum.toDouble()),
                                      SizedBox(width: 6),
                                      Text(
                                        '(${ratingNum.toStringAsFixed(1)})',
                                        style: TextStyle(
                                          color: Colors.grey[600],
                                          fontSize: 13,
                                          fontFamily: 'Roboto',
                                        ),
                                      ),
                                    ],
                                  ),
                                ] else ...[
                                  Text(
                                    'No reviews yet',
                                    style: TextStyle(
                                      color: Colors.grey[500],
                                      fontSize: 13,
                                      fontStyle: FontStyle.italic,
                                      fontFamily: 'Roboto',
                                    ),
                                  ),
                                ],
                                SizedBox(height: 8),
                                // Rate
                                if (rateVal != null) ...[
                                  Container(
                                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: coral.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.monetization_on,
                                          size: 16,
                                          color: coral,
                                        ),
                                        SizedBox(width: 4),
                                        Text(
                                          '₱$rateVal/hour',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            color: deepRed,
                                            fontSize: 13,
                                            fontFamily: 'Roboto',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 16),
                      // Address and experience chips
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildInfoChip(
                            icon: Icons.location_on,
                            label: sitter['address'] ?? 'Location not specified',
                            color: Colors.blue,
                          ),
                          if (sitter['experience'] != null)
                            _buildInfoChip(
                              icon: Icons.star,
                              label: '${sitter['experience']} yrs exp',
                              color: Colors.orange,
                            ),
                        ],
                      ),
                      SizedBox(height: 16),
                      // Action buttons
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _showSitterReviewsModal(sitter),
                              icon: Icon(Icons.rate_review, size: 18),
                              label: Text('Reviews'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: coral,
                                side: BorderSide(color: coral),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                padding: EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: pendingSitterIds.contains(sitter['id']) 
                                ? null
                                : () => _showHireModal(sitter),
                              icon: Icon(
                                pendingSitterIds.contains(sitter['id']) 
                                  ? Icons.hourglass_top 
                                  : Icons.pets,
                                size: 18,
                              ),
                              label: Text(
                                pendingSitterIds.contains(sitter['id']) 
                                  ? 'Pending' 
                                  : 'Hire',
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: pendingSitterIds.contains(sitter['id']) 
                                  ? Colors.grey 
                                  : Colors.green,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                padding: EdgeInsets.symmetric(vertical: 12),
                                elevation: pendingSitterIds.contains(sitter['id']) ? 0 : 2,
                              ),
                            ),
                          ),
                          SizedBox(width: 8),
                          Container(
                            decoration: BoxDecoration(
                              color: coral.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: IconButton(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => ChatDetailScreen(
                                      userId: widget.userId,
                                      receiverId: sitter['id'],
                                      userName: sitter['name'] ?? 'Sitter',
                                    ),
                                  ),
                                );
                              },
                              icon: Icon(
                                Icons.message,
                                color: coral,
                                size: 20,
                              ),
                              tooltip: 'Send Message',
                            ),
                          ),
                        ],
                      ),
                      
                      // Bio section
                      if (sitter['bio'] != null && sitter['bio'].toString().isNotEmpty) ...[
                        SizedBox(height: 16),
                        Container(
                          width: double.infinity,
                          padding: EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: lightBlush.withOpacity(0.5),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: coral.withOpacity(0.2)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.person,
                                    size: 16,
                                    color: coral,
                                  ),
                                  SizedBox(width: 6),
                                  Text(
                                    'About',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: deepRed,
                                      fontSize: 13,
                                      fontFamily: 'Roboto',
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 6),
                              Text(
                                sitter['bio'].toString(),
                                style: TextStyle(
                                  color: Colors.grey[700],
                                  fontSize: 13,
                                  height: 1.4,
                                  fontFamily: 'Roboto',
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // 👩‍⚕️ Pet Sitter Home
  Widget _buildSitterHome() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // REPLACED old header texts with redesigned greeting
        _buildSitterGreeting(),
        SizedBox(height: 24),

        // Enhanced: Availability toggle with modern design
        _buildEnhancedAvailabilityCard(),

        SizedBox(height: 12),

        // NEW: Edit Profile button
        Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          elevation: 2,
          child: ListTile(
            leading: Icon(Icons.edit, color: deepRed),
            title: Text('Edit Profile', style: TextStyle(fontWeight: FontWeight.w600, color: deepRed, fontFamily: 'Roboto')),
            subtitle: Text(
              'Update your bio, experience, and hourly rate',
              style: TextStyle(color: Colors.grey[700], fontFamily: 'Roboto'),
            ),
            trailing: Icon(Icons.chevron_right, color: deepRed),
            onTap: _showEditProfileModal,
          ),
        ),

        SizedBox(height: 12),

        // Enhanced: Profile summary with modern design
        if (_sitterProfile != null)
          _buildEnhancedProfileCard(),

        SizedBox(height: 12),

        // NEW: Quick stats row
        _buildSitterStatsRow(),

        SizedBox(height: 16),

        // ✅ Enhanced Assigned Jobs Section
        _buildEnhancedJobsSection(),

        SizedBox(height: 24),

        // ⭐ Enhanced Reviews Section
        _buildEnhancedReviewsSection(),

        SizedBox(height: 24),

        // 🧾 Enhanced Completed Jobs Section
        _buildEnhancedCompletedJobsCard(),
      ],
    );
  }

  // Enhanced review card for modal display
  Widget _buildEnhancedReviewCard(Map<String, dynamic> review) {
    final ratingNum = (review['rating'] is num) ? (review['rating'] as num).toDouble() : 0.0;
    final comment = (review['comment'] ?? '').toString();
    final owner = (review['owner_name'] ?? 'Pet Owner').toString();
    final createdAt = review['created_at']?.toString();
    
    final reviewerName = review['reviewer_name']?.toString() ?? owner;
    final reviewerProfilePicture = (review['reviewer_profile_picture'] ??
        (review['users'] as Map<String, dynamic>?)?['profile_picture'])
      ?.toString();
    
    String timeAgo = 'Recently';
    if (createdAt != null) {
      try {
        final date = DateTime.parse(createdAt);
        final now = DateTime.now();
        final difference = now.difference(date);
        if (difference.inDays > 0) {
          timeAgo = '${difference.inDays} day${difference.inDays > 1 ? 's' : ''} ago';
        } else if (difference.inHours > 0) {
          timeAgo = '${difference.inHours} hour${difference.inHours > 1 ? 's' : ''} ago';
        } else {
          timeAgo = 'Recently';
        }
      } catch (_) {}
    }

    return Container(
      width: 280, // Set fixed width for horizontal ListView
      height: 200, // Set fixed height to prevent overflow
      padding: EdgeInsets.all(16), // Reduced padding
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: coral.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: deepRed.withOpacity(0.08),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min, // Use minimum space needed
        children: [
          // Header with rating and time
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(children: _buildRatingStars(ratingNum)),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: coral.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  timeAgo,
                  style: TextStyle(
                    fontSize: 10,
                    color: coral,
                    fontWeight: FontWeight.w500,
                    fontFamily: 'Roboto',
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          
          // Comment
          if (comment.isNotEmpty) ...[
            Expanded(
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: lightBlush.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: peach.withOpacity(0.3)),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    '"$comment"',
                    style: TextStyle(
                      fontStyle: FontStyle.italic,
                      fontSize: 13,
                      color: Colors.grey[700],
                      fontFamily: 'Roboto',
                      height: 1.3,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            SizedBox(height: 8),
          ],
          
          // Owner info with profile picture
          Row(
            children: [
              // Profile picture or default avatar
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: coral.withOpacity(0.3)),
                ),
                child: ClipOval(
                  child: reviewerProfilePicture != null && reviewerProfilePicture.isNotEmpty
                      ? Image.network(
                          reviewerProfilePicture,
                          width: 28,
                          height: 28,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [coral, peach],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  reviewerName.isNotEmpty ? reviewerName[0].toUpperCase() : 'O',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    fontFamily: 'Roboto',
                                  ),
                                ),
                              ),
                            );
                          },
                        )
                      : Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [coral, peach],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              reviewerName.isNotEmpty ? reviewerName[0].toUpperCase() : 'O',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                fontFamily: 'Roboto',
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      reviewerName,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: deepRed,
                        fontFamily: 'Roboto',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'Pet Owner',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[600],
                        fontFamily: 'Roboto',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _buildRatingStars(double rating) {
    final full = rating.floor();
    final half = (rating - full) >= 0.5;
    return List<Widget>.generate(5, (i) {
      if (i < full) {
        return Icon(Icons.star, size: 18, color: Colors.orange);
      } else if (i == full && half) {
        return Icon(Icons.star_half, size: 18, color: Colors.orange);
      }
      return Icon(Icons.star_border, size: 18, color: Colors.orange);
    });
  }

  // NEW: load sitter availability from sitters by user_id
  Future<void> fetchSitterAvailability() async {
    try {
      final row = await _fastApi.fetchSitterProfile(widget.userId);
      setState(() => _isSitterAvailable = (row['is_available'] == true));
    } catch (e) {
      print('❌ fetchSitterAvailability ERROR: $e');
      setState(() => _isSitterAvailable = false);
    }
  }

  // NEW: fetch sitter profile data
  Future<void> fetchSitterProfile() async {
    try {
      final row = await _fastApi.fetchSitterProfile(widget.userId);
      setState(() => _sitterProfile = row);
    } catch (e) {
      print('❌ fetchSitterProfile ERROR: $e');
      setState(() => _sitterProfile = null);
    }
  }

  // NEW: update sitter profile
  Future<void> updateSitterProfile({
    String? bio,
    int? experience,
    double? hourlyRate,
  }) async {
    setState(() => _isLoadingProfile = true);
    try {
      final updates = <String, dynamic>{};
      if (bio != null) updates['bio'] = bio;
      if (experience != null) updates['experience'] = experience;
      if (hourlyRate != null) updates['hourly_rate'] = hourlyRate;

      await _fastApi.updateSitterProfile(widget.userId, updates);

      // Refresh profile data
      await fetchSitterProfile();
      
      if (mounted) {
        _showEnhancedSnackBar('Profile updated successfully!');
      }
    } catch (e) {
      print('❌ updateSitterProfile ERROR: $e');
      if (mounted) {
        _showEnhancedSnackBar('Failed to update profile: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isLoadingProfile = false);
    }
  }

  // Search functionality
  Future<void> _performSearch(String query) async {
    setState(() {
      _currentSearchQuery = query.trim();
    });
    await fetchAvailableSitters(locationQuery: _currentSearchQuery.isEmpty ? null : _currentSearchQuery);
  }

  void _clearSearch() {
    setState(() {
      _currentSearchQuery = '';
      _locationSearchController.clear();
    });
    fetchAvailableSitters(); // Fetch all sitters without filter
  }

  // Helper method for consistent SnackBar styling
  void _showEnhancedSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w500,
          ),
        ),
        backgroundColor: isError ? deepRed : coral,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        margin: EdgeInsets.all(16),
        elevation: 8,
        duration: Duration(seconds: 3),
      ),
    );
  }

  // NEW: toggle and persist sitter availability
  Future<void> _setSitterAvailability(bool value) async {
    if (_isUpdatingAvailability) return;
    setState(() {
      _isUpdatingAvailability = true;
      _isSitterAvailable = value; // optimistic
    });
    try {
      await _fastApi.updateSitterProfile(widget.userId, {'is_available': value});
      if (mounted) {
        _showEnhancedSnackBar(value ? 'You are now Available.' : 'You are now Busy.');
      }
    } catch (e) {
      // revert on failure
      setState(() => _isSitterAvailable = !value);
      if (mounted) {
        _showEnhancedSnackBar('Failed to update availability: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isUpdatingAvailability = false);
    }
  }

  // Enhanced edit profile modal with modern design
  Future<void> _showEditProfileModal() async {
    if (_sitterProfile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Profile data not loaded yet. Please try again.'),
          backgroundColor: deepRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final TextEditingController bioController = TextEditingController(
      text: _sitterProfile!['bio']?.toString() ?? '',
    );
    final TextEditingController experienceController = TextEditingController(
      text: _sitterProfile!['experience']?.toString() ?? '',
    );
    final TextEditingController rateController = TextEditingController(
      text: _sitterProfile!['hourly_rate']?.toString() ?? '',
    );

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.85,
              decoration: BoxDecoration(
                color: lightBlush,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                children: [
                  // Enhanced header
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.fromLTRB(20, 16, 20, 20),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [deepRed, coral],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                    ),
                    child: Column(
                      children: [
                        // Handle bar
                        Container(
                          height: 4,
                          width: 40,
                          margin: EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        // Header content
                        Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.edit,
                                color: Colors.white,
                                size: 24,
                              ),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Edit Profile',
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Colors.white70,
                                      fontFamily: 'Roboto',
                                    ),
                                  ),
                                  Text(
                                    'Update your information',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                      fontFamily: 'Roboto',
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
                  // Content area
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Bio section
                            Container(
                              padding: EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: coral.withOpacity(0.2)),
                                boxShadow: [
                                  BoxShadow(
                                    color: deepRed.withOpacity(0.08),
                                    blurRadius: 8,
                                    offset: Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.person,
                                        color: coral,
                                        size: 20,
                                      ),
                                      SizedBox(width: 8),
                                      Text(
                                        'About You',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: deepRed,
                                          fontFamily: 'Roboto',
                                        ),
                                      ),
                                    ],
                                  ),
                                  SizedBox(height: 12),
                                  TextField(
                                    controller: bioController,
                                    maxLines: 4,
                                    decoration: InputDecoration(
                                      hintText: 'Tell pet owners about yourself, your experience, and what makes you special...',
                                      hintStyle: TextStyle(color: Colors.grey[400]),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: BorderSide(color: coral.withOpacity(0.3)),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: BorderSide(color: coral, width: 2),
                                      ),
                                      filled: true,
                                      fillColor: lightBlush.withOpacity(0.3),
                                      contentPadding: EdgeInsets.all(16),
                                    ),
                                    style: TextStyle(fontFamily: 'Roboto'),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(height: 20),
                            
                            // Experience and Rate row
                            Row(
                              children: [
                                // Experience section
                                Expanded(
                                  child: Container(
                                    padding: EdgeInsets.all(20),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(color: coral.withOpacity(0.2)),
                                      boxShadow: [
                                        BoxShadow(
                                          color: deepRed.withOpacity(0.08),
                                          blurRadius: 8,
                                          offset: Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.star,
                                              color: coral,
                                              size: 20,
                                            ),
                                            SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                'Experience',
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.bold,
                                                  color: deepRed,
                                                  fontFamily: 'Roboto',
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        SizedBox(height: 12),
                                        TextField(
                                          controller: experienceController,
                                          keyboardType: TextInputType.number,
                                          decoration: InputDecoration(
                                            hintText: 'Years',
                                            hintStyle: TextStyle(color: Colors.grey[400]),
                                            border: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(8),
                                              borderSide: BorderSide(color: coral.withOpacity(0.3)),
                                            ),
                                            focusedBorder: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(8),
                                              borderSide: BorderSide(color: coral, width: 2),
                                            ),
                                            filled: true,
                                            fillColor: lightBlush.withOpacity(0.3),
                                            contentPadding: EdgeInsets.all(12),
                                            isDense: true,
                                          ),
                                          style: TextStyle(fontFamily: 'Roboto'),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                SizedBox(width: 12),
                                // Rate section
                                Expanded(
                                  child: Container(
                                    padding: EdgeInsets.all(20),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(color: coral.withOpacity(0.2)),
                                      boxShadow: [
                                        BoxShadow(
                                          color: deepRed.withOpacity(0.08),
                                          blurRadius: 8,
                                          offset: Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.monetization_on,
                                              color: coral,
                                              size: 20,
                                            ),
                                            SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                'Hourly Rate',
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.bold,
                                                  color: deepRed,
                                                  fontFamily: 'Roboto',
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        SizedBox(height: 12),
                                        TextField(
                                          controller: rateController,
                                          keyboardType: TextInputType.numberWithOptions(decimal: true),
                                          decoration: InputDecoration(
                                            hintText: '₱/hour',
                                            hintStyle: TextStyle(color: Colors.grey[400]),
                                            border: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(8),
                                              borderSide: BorderSide(color: coral.withOpacity(0.3)),
                                            ),
                                            focusedBorder: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(8),
                                              borderSide: BorderSide(color: coral, width: 2),
                                            ),
                                            filled: true,
                                            fillColor: lightBlush.withOpacity(0.3),
                                            contentPadding: EdgeInsets.all(12),
                                            isDense: true,
                                          ),
                                          style: TextStyle(fontFamily: 'Roboto'),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: 30),
                            
                            // Action buttons
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () => Navigator.of(context).pop(),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.red,
                                      side: BorderSide(color: Colors.red),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      padding: EdgeInsets.symmetric(vertical: 16),
                                    ),
                                    child: Text(
                                      'Cancel',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontFamily: 'Roboto',
                                        color: Colors.red,
                                      ),
                                    ),
                                  ),
                                ),
                                SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: _isLoadingProfile ? null : () async {
                                      // Validate inputs
                                      final bio = bioController.text.trim();
                                      final experienceText = experienceController.text.trim();
                                      final rateText = rateController.text.trim();
                                      
                                      int? experience;
                                      double? hourlyRate;
                                      
                                      if (experienceText.isNotEmpty) {
                                        experience = int.tryParse(experienceText);
                                        if (experience == null || experience < 0) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('Please enter a valid experience in years'),
                                              backgroundColor: deepRed,
                                              behavior: SnackBarBehavior.floating,
                                            ),
                                          );
                                          return;
                                        }
                                      }
                                      
                                      if (rateText.isNotEmpty) {
                                        hourlyRate = double.tryParse(rateText);
                                        if (hourlyRate == null || hourlyRate <= 0) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('Please enter a valid hourly rate'),
                                              backgroundColor: deepRed,
                                              behavior: SnackBarBehavior.floating,
                                            ),
                                          );
                                          return;
                                        }
                                      }
                                      
                                      Navigator.of(context).pop();
                                      await updateSitterProfile(
                                        bio: bio.isEmpty ? null : bio,
                                        experience: experience,
                                        hourlyRate: hourlyRate,
                                      );
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.green,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      padding: EdgeInsets.symmetric(vertical: 16),
                                      elevation: 2,
                                    ),
                                    child: _isLoadingProfile 
                                        ? SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              color: Colors.white,
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : Text(
                                            'Save Changes',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontFamily: 'Roboto',
                                            ),
                                          ),
                                  ),
                                ),
                              ],
                            ),
                          ],
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

  // Helper methods for enhanced UI components
  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: coral.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              size: 40,
              color: coral,
            ),
          ),
          SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: deepRed,
              fontFamily: 'Roboto',
            ),
          ),
          SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[600],
              fontFamily: 'Roboto',
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultAvatar(String name, {double size = 54}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [coral, peach],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : 'S',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            fontFamily: 'Roboto',
          ),
        ),
      ),
    );
  }

  Widget _buildCircularAvatar({
    required String name,
    String? imageUrl,
    double size = 48,
    Color? borderColor,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: borderColor != null ? Border.all(color: borderColor, width: 2) : null,
      ),
      child: ClipOval(
        child: imageUrl != null && imageUrl.isNotEmpty
            ? Image.network(
                imageUrl,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildDefaultAvatar(name, size: size),
              )
            : _buildDefaultAvatar(name, size: size),
      ),
    );
  }

  Widget _buildInfoChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: color,
          ),
          SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: color.withOpacity(0.8),
                fontFamily: 'Roboto',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // Enhanced profile card with modern design
  Widget _buildEnhancedProfileCard() {
    final bio = _sitterProfile!['bio']?.toString() ?? '';
    final experience = _sitterProfile!['experience'];
    final hourlyRate = _sitterProfile!['hourly_rate'];
    
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.white, lightBlush.withOpacity(0.3)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: coral.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: deepRed.withOpacity(0.08),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with icon
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [coral, peach]),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.person, color: Colors.white, size: 20),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Your Profile',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: deepRed,
                    fontFamily: 'Roboto',
                  ),
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: (_isSitterAvailable ?? false) ? Colors.green[50] : Colors.red[50],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: (_isSitterAvailable ?? false) ? Colors.green[300]! : Colors.red[300]!,
                  ),
                ),
                child: Text(
                  (_isSitterAvailable ?? false) ? 'ACTIVE' : 'OFFLINE',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: (_isSitterAvailable ?? false) ? Colors.green[700] : Colors.red[700],
                    fontFamily: 'Roboto',
                  ),
                ),
              ),
            ],
          ),
          
          SizedBox(height: 16),
          
          // Stats grid
          Row(
            children: [
              Expanded(
                child: _buildProfileStatCard(
                  icon: Icons.work_history,
                  label: 'Experience',
                  value: experience != null ? '${experience} years' : 'Not set',
                  color: coral,
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: _buildProfileStatCard(
                  icon: Icons.monetization_on,
                  label: 'Hourly Rate',
                  value: hourlyRate != null ? '₱ ${hourlyRate}/hr' : 'Not set',
                  color: Colors.green[600]!,
                ),
              ),
            ],
          ),
          
          if (bio.isNotEmpty) ...[
            SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: lightBlush.withOpacity(0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: peach.withOpacity(0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline, size: 16, color: deepRed),
                      SizedBox(width: 6),
                      Text(
                        'Bio',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: deepRed,
                          fontSize: 12,
                          fontFamily: 'Roboto',
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    bio,
                    style: TextStyle(
                      color: Colors.grey[700],
                      fontFamily: 'Roboto',
                      height: 1.4,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Profile stat card helper
  Widget _buildProfileStatCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey[600],
              fontFamily: 'Roboto',
            ),
          ),
          SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: color,
              fontFamily: 'Roboto',
            ),
          ),
        ],
      ),
    );
  }

  // Enhanced stats row for sitters
  Widget _buildSitterStatsRow() {
    // Calculate rating from reviews
    double avgRating = 0.0;
    if (sitterReviews.isNotEmpty) {
      final num sum = sitterReviews.fold<num>(0, (acc, review) {
        return acc + ((review['rating'] ?? 0) as num);
      });
      avgRating = (sum / sitterReviews.length).toDouble();
    }

    final pendingJobsCount = sittingJobs.where((j) => 
      (j['status'] ?? '').toString().toLowerCase() == 'pending').length;
    final activeJobsCount = sittingJobs.where((j) => 
      (j['status'] ?? '').toString().toLowerCase() == 'active').length;
    
    return SizedBox(
      width: double.infinity,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: _buildStatCard(
              icon: Icons.star,
              label: 'Rating',
              value: avgRating > 0 ? avgRating.toStringAsFixed(1) : '0.0',
              color: Colors.amber[600]!,
              suffix: '★',
            ),
          ),
          SizedBox(width: 14),
          Expanded(
            child: _buildStatCard(
              icon: Icons.pending_actions,
              label: 'Pending',
              value: '$pendingJobsCount',
              color: Colors.red[600]!,
            ),
          ),
          SizedBox(width: 14),
          Expanded(
            child: _buildStatCard(
              icon: Icons.work,
              label: 'Active',
              value: '$activeJobsCount',
              color: Colors.blue[600]!,
            ),
          ),
          SizedBox(width: 14),
          Expanded(
            child: _buildStatCard(
              icon: Icons.task_alt,
              label: 'Completed',
              value: '$completedJobsCount',
              color: Colors.green[600]!,
            ),
          ),
        ],
      ),
    );
  }

  // Enhanced stat card
  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    String? suffix,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 18, horizontal: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.white, color.withOpacity(0.08)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.25), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.12),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: color.withOpacity(0.2), width: 1),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: color,
                  fontFamily: 'Roboto',
                ),
              ),
              if (suffix != null)
                Padding(
                  padding: EdgeInsets.only(left: 3),
                  child: Text(
                    suffix,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: color.withOpacity(0.9),
                      fontFamily: 'Roboto',
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey[700],
              fontFamily: 'Roboto',
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  // Enhanced jobs section with modern design
  Widget _buildEnhancedJobsSection() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.white, lightBlush.withOpacity(0.2)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: coral.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: deepRed.withOpacity(0.08),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with filter
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [coral, peach]),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.work, color: Colors.white, size: 20),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Assigned Jobs',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: deepRed,
                    fontFamily: 'Roboto',
                  ),
                ),
              ),
              // Enhanced filter dropdown
              Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: coral.withOpacity(0.3)),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _jobsStatusFilter,
                    icon: Icon(Icons.filter_list, color: coral, size: 18),
                    items: _jobStatusOptions.map((status) {
                      return DropdownMenuItem<String>(
                        value: status,
                        child: Text(
                          status,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: deepRed,
                            fontFamily: 'Roboto',
                          ),
                        ),
                      );
                    }).toList(),
                    onChanged: (value) => setState(() => _jobsStatusFilter = value ?? 'All'),
                  ),
                ),
              ),
            ],
          ),

          SizedBox(height: 16),

          // Jobs list
          Builder(builder: (context) {
            final filtered = _jobsStatusFilter == 'All'
                ? sittingJobs
                : sittingJobs.where((j) => 
                    (j['status'] ?? '').toString().toLowerCase() == _jobsStatusFilter.toLowerCase()
                  ).toList();

            if (filtered.isEmpty) {
              return _buildEmptyJobsState();
            }

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: filtered.map((job) => _buildEnhancedJobCard(job)).toList(),
            );
          }),
        ],
      ),
    );
  }

  // Enhanced job card with modern design
  Widget _buildEnhancedJobCard(Map<String, dynamic> job) {
    final petName = job['pet_name'] ?? 'Pet';
    final petType = job['pet_type'] ?? 'Pet';
    final petProfilePicture = job['pets']?['profile_picture']?.toString();
    final startTime = job['start_date'] ?? 'Time not set';
    final endTime = job['end_date'] ?? 'Time not set';
    final status = (job['status'] ?? 'Pending').toString();
    final ownerName = job['owner_name'] ?? 'Owner';
    final String? ownerId = job['owner_id'] as String?;
    final String jobId = job['id'].toString();

    Color statusColor = _getStatusColor(status);

    return Container(
      margin: EdgeInsets.only(bottom: 16),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusColor.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: statusColor.withOpacity(0.1),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              _buildPetProfileAvatar(profilePicture: petProfilePicture, size: 50),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$petName ($petType)',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: deepRed,
                        fontFamily: 'Roboto',
                      ),
                    ),
                    Text(
                      'Owner: $ownerName',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                        fontFamily: 'Roboto',
                      ),
                    ),
                  ],
                ),
              ),
              _buildStatusBadge(status, statusColor),
            ],
          ),

          SizedBox(height: 12),

          // Time info
          Container(
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: lightBlush.withOpacity(0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Icon(Icons.schedule, size: 16, color: Colors.grey[600]),
                      SizedBox(width: 6),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Start',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey[600],
                              fontFamily: 'Roboto',
                            ),
                          ),
                          Text(
                            startTime,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              fontFamily: 'Roboto',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 1,
                  height: 30,
                  color: Colors.grey[300],
                ),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'End',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey[600],
                              fontFamily: 'Roboto',
                            ),
                          ),
                          Text(
                            endTime,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              fontFamily: 'Roboto',
                            ),
                          ),
                        ],
                      ),
                      SizedBox(width: 6),
                      Icon(Icons.event, size: 16, color: Colors.grey[600]),
                    ],
                  ),
                ),
              ],
            ),
          ),

          SizedBox(height: 12),

          // Action buttons
          if (status == 'Pending')
            SizedBox(
              width: double.infinity,
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      onPressed: () => _updateJobStatus(jobId, 'Active'),
                      icon: Icon(Icons.task_alt, size: 18),
                      label: Text('Accept', style: TextStyle(fontFamily: 'Roboto')),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green[600],
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _updateJobStatus(jobId, 'Cancelled'),
                      icon: Icon(Icons.cancel, size: 16, color: Colors.red[600]),
                      label: Text('Decline', style: TextStyle(color: Colors.red[600], fontFamily: 'Roboto')),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.red[600]!),
                        padding: EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: ownerId != null ? () => _openChatWithOwner(ownerId, ownerName: ownerName) : null,
                      icon: Icon(Icons.message, size: 16),
                      label: Text('Chat', style: TextStyle(fontFamily: 'Roboto')),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: coral,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ),
            )
          else ...[
            SizedBox(
              width: double.infinity,
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: ownerId != null ? () => _openChatWithOwner(ownerId, ownerName: ownerName) : null,
                      icon: Icon(Icons.message, size: 18),
                      label: Text('Message Owner', style: TextStyle(fontFamily: 'Roboto')),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: coral,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  // Complete button removed - only owners can mark jobs as complete
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Helper methods for job status
  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'active':
        return Colors.green[600]!;
      case 'completed':
        return Colors.blue[600]!;
      case 'cancelled':
        return Colors.red[600]!;
      default:
        return Colors.orange[600]!;
    }
  }

  Widget _buildStatusBadge(String status, Color color) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
          fontFamily: 'Roboto',
        ),
      ),
    );
  }

  Widget _buildEmptyJobsState() {
    return Container(
      padding: EdgeInsets.all(32),
      child: Column(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: coral.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.work_outline,
              size: 30,
              color: coral,
            ),
          ),
          SizedBox(height: 16),
          Text(
            'No Jobs Found',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: deepRed,
              fontFamily: 'Roboto',
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Jobs matching your filter will appear here',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
              fontFamily: 'Roboto',
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // Enhanced reviews section
  Widget _buildEnhancedReviewsSection() {
    // Calculate overall rating
    double avgRating = 0.0;
    if (sitterReviews.isNotEmpty) {
      final num sum = sitterReviews.fold<num>(0, (acc, review) {
        return acc + ((review['rating'] ?? 0) as num);
      });
      avgRating = (sum / sitterReviews.length).toDouble();
    }

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.white, Colors.orange[50]!.withOpacity(0.3)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.orange.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.orange.withOpacity(0.08),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with rating summary
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [Colors.orange[400]!, Colors.orange[600]!]),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.star, color: Colors.white, size: 20),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Reviews',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: deepRed,
                        fontFamily: 'Roboto',
                      ),
                    ),
                    if (sitterReviews.isNotEmpty)
                      Row(
                        children: [
                          Row(children: _buildRatingStars(avgRating)),
                          SizedBox(width: 8),
                          Text(
                            '${avgRating.toStringAsFixed(1)} (${sitterReviews.length} reviews)',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                              fontFamily: 'Roboto',
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),

          SizedBox(height: 16),

          if (sitterReviews.isEmpty)
            _buildEmptyReviewsState()
          else
            SizedBox(
              height: 180,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: sitterReviews.length,
                separatorBuilder: (_, __) => SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final review = sitterReviews[index] as Map<String, dynamic>;
                  return _buildEnhancedReviewCard(review);
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyReviewsState() {
    return Container(
      padding: EdgeInsets.all(32),
      child: Column(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.star_outline,
              size: 30,
              color: Colors.orange[600],
            ),
          ),
          SizedBox(height: 16),
          Text(
            'No Reviews Yet',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: deepRed,
              fontFamily: 'Roboto',
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Your reviews from pet owners will appear here',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
              fontFamily: 'Roboto',
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // Enhanced availability card with modern design and status indicators
  Widget _buildEnhancedAvailabilityCard() {
    final isAvailable = _isSitterAvailable ?? false;
    final isUpdating = _isUpdatingAvailability;
    
    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isAvailable
              ? [Colors.green[400]!, Colors.green[600]!]
              : [Colors.red[400]!, Colors.red[600]!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: (isAvailable ? Colors.green : Colors.red).withOpacity(0.3),
            blurRadius: 12,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Stack(
        children: [
          // Background decorative elements
          Positioned(
            top: -20,
            right: -20,
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            bottom: -30,
            left: -30,
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                shape: BoxShape.circle,
              ),
            ),
          ),
          
          // Main content
          Padding(
            padding: EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Status icon with animation
                    AnimatedContainer(
                      duration: Duration(milliseconds: 300),
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withOpacity(0.3),
                          width: 2,
                        ),
                      ),
                      child: isUpdating
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : Icon(
                              isAvailable ? Icons.work : Icons.work_off,
                              color: Colors.white,
                              size: 20,
                            ),
                    ),
                    
                    SizedBox(width: 16),
                    
                    // Status text
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isAvailable ? 'Available for Jobs' : 'Currently Busy',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              fontFamily: 'Roboto',
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            isAvailable
                                ? 'Pet owners can see and hire you'
                                : 'You appear offline to pet owners',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white.withOpacity(0.9),
                              fontFamily: 'Roboto',
                            ),
                          ),
                        ],
                      ),
                    ),
                    
                    // Toggle switch
                    AnimatedContainer(
                      duration: Duration(milliseconds: 300),
                      child: Transform.scale(
                        scale: 1.2,
                        child: Switch(
                          value: isAvailable,
                          onChanged: isUpdating || _isSitterAvailable == null 
                              ? null 
                              : _setSitterAvailability,
                          activeColor: Colors.white,
                          activeTrackColor: Colors.white.withOpacity(0.3),
                          inactiveThumbColor: Colors.white.withOpacity(0.8),
                          inactiveTrackColor: Colors.white.withOpacity(0.2),
                        ),
                      ),
                    ),
                  ],
                ),
                
                if (isAvailable) ...[
                  SizedBox(height: 16),
                  Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.2),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.visibility,
                          color: Colors.white.withOpacity(0.9),
                          size: 18,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'You\'re visible in search results and can receive job requests',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.white.withOpacity(0.9),
                              fontFamily: 'Roboto',
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
        ],
      ),
    );
  }

  // Enhanced completed jobs card with statistics and achievements
  Widget _buildEnhancedCompletedJobsCard() {
    // Calculate completion rate and recent activity
    final totalJobs = sittingJobs.length;
    final completionRate = totalJobs > 0 ? (completedJobsCount / totalJobs * 100).round() : 0;
    
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.white, lightBlush.withOpacity(0.2)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.green.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.green.withOpacity(0.1),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with trophy icon
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.amber[400]!, Colors.orange[500]!],
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.amber.withOpacity(0.3),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.emoji_events,
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
                      'Job Completion Record',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.green[800],
                        fontFamily: 'Roboto',
                      ),
                    ),
                    Text(
                      'Your professional achievement summary',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.green[600],
                        fontFamily: 'Roboto',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          
          SizedBox(height: 20),
          
          // Main statistics row
          Row(
            children: [
              // Completed jobs count
              Expanded(
                child: _buildJobStatCard(
                  icon: Icons.task_alt,
                  title: 'Completed',
                  value: completedJobsCount.toString(),
                  subtitle: completedJobsCount == 1 ? 'Job' : 'Jobs',
                  color: Colors.green,
                  isMainStat: true,
                ),
              ),
              SizedBox(width: 16),
              
              // Completion rate
              Expanded(
                child: _buildJobStatCard(
                  icon: Icons.trending_up,
                  title: 'Success Rate',
                  value: '$completionRate%',
                  subtitle: 'Completion',
                  color: Colors.blue,
                ),
              ),
            ],
          ),
          
          if (completedJobsCount > 0) ...[
            SizedBox(height: 16),
            
            // Achievement badges
            _buildAchievementBadges(),
            
            SizedBox(height: 16),
            
            // Progress message
            Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.green[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.green.withOpacity(0.2)),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.star,
                    color: Colors.green[600],
                    size: 20,
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _getProgressMessage(),
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.green[700],
                        fontWeight: FontWeight.w500,
                        fontFamily: 'Roboto',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.withOpacity(0.2)),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.work_outline,
                    color: Colors.grey[600],
                    size: 20,
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Start taking on jobs to build your completion record and earn achievements!',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[600],
                        fontFamily: 'Roboto',
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

  // Helper widget for job statistics cards
  Widget _buildJobStatCard({
    required IconData icon,
    required String title,
    required String value,
    required String subtitle,
    required Color color,
    bool isMainStat = false,
  }) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withOpacity(0.2),
          width: isMainStat ? 2 : 1,
        ),
      ),
      child: Column(
        children: [
          Icon(
            icon,
            color: (color is MaterialColor) ? color[600] : color,
            size: isMainStat ? 28 : 24,
          ),
          SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: isMainStat ? 24 : 20,
              fontWeight: FontWeight.bold,
              color: (color is MaterialColor) ? color[800] : color,
              fontFamily: 'Roboto',
            ),
          ),
          SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 12,
              color: (color is MaterialColor) ? color[600] : color,
              fontFamily: 'Roboto',
            ),
          ),
          SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              color: (color is MaterialColor) ? color[500] : color,
              fontWeight: FontWeight.w500,
              fontFamily: 'Roboto',
            ),
          ),
        ],
      ),
    );
  }

  // Achievement badges based on completed jobs
  Widget _buildAchievementBadges() {
    List<Widget> badges = [];
    
    if (completedJobsCount >= 1) {
      badges.add(_buildAchievementBadge(
        icon: Icons.star,
        title: 'First Success',
        description: 'Completed your first job',
        color: Colors.blue,
      ));
    }
    
    if (completedJobsCount >= 5) {
      badges.add(_buildAchievementBadge(
        icon: Icons.workspace_premium,
        title: 'Experienced',
        description: '5+ jobs completed',
        color: Colors.purple,
      ));
    }
    
    if (completedJobsCount >= 10) {
      badges.add(_buildAchievementBadge(
        icon: Icons.emoji_events,
        title: 'Professional',
        description: '10+ jobs completed',
        color: Colors.amber,
      ));
    }
    
    if (completedJobsCount >= 25) {
      badges.add(_buildAchievementBadge(
        icon: Icons.diamond,
        title: 'Expert Sitter',
        description: '25+ jobs completed',
        color: Colors.green,
      ));
    }
    
    if (badges.isEmpty) return SizedBox.shrink();
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Achievements Unlocked',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.green[700],
            fontFamily: 'Roboto',
          ),
        ),
        SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: badges,
        ),
      ],
    );
  }

  // Individual achievement badge
  Widget _buildAchievementBadge({
    required IconData icon,
    required String title,
    required String description,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withOpacity(0.1), color.withOpacity(0.05)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            color: (color is MaterialColor) ? color[600] : color,
            size: 16,
          ),
          SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: (color is MaterialColor) ? color[700] : color,
              fontFamily: 'Roboto',
            ),
          ),
        ],
      ),
    );
  }

  // Progress message based on completion count
  String _getProgressMessage() {
    if (completedJobsCount >= 25) {
      return 'Outstanding! You\'re an expert pet sitter with incredible dedication.';
    } else if (completedJobsCount >= 10) {
      return 'Excellent work! You\'re building a strong professional reputation.';
    } else if (completedJobsCount >= 5) {
      return 'Great progress! You\'re becoming an experienced pet sitter.';
    } else if (completedJobsCount >= 1) {
      return 'Wonderful start! Keep up the great work to build your reputation.';
    }
    return 'Ready to start your pet sitting journey!';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: lightBlush,
      body: isLoading
          ? Center(child: CircularProgressIndicator(color: deepRed))
          : RefreshIndicator(
              onRefresh: _refreshAll,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.all(16),
                child: userRole == 'Pet Sitter' ? _buildSitterHome() : _buildOwnerHome(),
              ),
            ),
    );
  }
}
