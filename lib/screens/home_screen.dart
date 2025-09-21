import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:PetTrackCare/screens/chat_detail_screen.dart';

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
  final supabase = Supabase.instance.client;

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
  RealtimeChannel? _jobsChannel; // realtime subscription channel
  
  // Search controller for location search
  final TextEditingController _locationSearchController = TextEditingController();
  String _currentSearchQuery = '';

  @override
  void initState() {
    super.initState();
    fetchUserData();
    _loadJobs();
    _sitterTabController = TabController(length: 3, vsync: this);
  }

  Future<void> _loadJobs() async {
  final response = await supabase
      .from('sitting_jobs_with_owner')
      .select('id, status, start_date, end_date, pet_name, pet_type, owner_name, owner_id');

  setState(() {
    sittingJobs = response as List;
  });
}

  @override
  void dispose() {
    _sitterTabController.dispose();
    _locationSearchController.dispose();
    // unsubscribe realtime channel
    _jobsChannel?.unsubscribe();
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
      final userRes = await supabase.from('users').select().eq('id', widget.userId).maybeSingle();
      if (userRes == null) {
        _showEnhancedSnackBar('User profile not found. Please contact support.', isError: true);
        setState(() => isLoading = false);
        return;
      }

      setState(() {
        userRole = userRes['role'];
        userName = userRes['name'];
      });

      await Future.wait([
        if (userRole == 'Pet Sitter') fetchSittingJobs(),
        if (userRole == 'Pet Sitter') fetchSitterReviews(),
        if (userRole == 'Pet Sitter') fetchSitterAvailability(), // NEW: load availability
        if (userRole == 'Pet Sitter') fetchSitterProfile(), // NEW: load profile
        if (userRole == 'Pet Owner') fetchOwnedPets(),
        if (userRole == 'Pet Owner') fetchAvailableSitters(),
        fetchDailySummary()
      ]);

      // subscribe to realtime after initial data load (pets and jobs ready)
      _setupRealtime();

      setState(() => isLoading = false);
    } catch (e) {
      print('❌ fetchUserData ERROR: $e');
      setState(() => isLoading = false);
    }
  }

  Future<void> fetchAvailableSitters({String? locationQuery}) async {
    try {
      // Get all sitters with their basic info from public.users including address
      final rows = await supabase
          .from('sitters')
          .select('id, user_id, is_available, hourly_rate, bio, experience, users!inner(id, name, role, profile_picture, address), sitter_reviews(rating)')
          .eq('users.role', 'Pet Sitter');

      final List<dynamic> list = (rows as List?) ?? [];
      
      // Map the data with address from public.users
      final sittersWithAddress = list.map<Map<String, dynamic>>((raw) {
        final m = Map<String, dynamic>.from(raw as Map);
        final user = (m['users'] as Map?) ?? {};
        final reviews = (m['sitter_reviews'] as List?) ?? [];
        final userId = (m['user_id'] ?? user['id'])?.toString();
        
        double? avgRating;
        if (reviews.isNotEmpty) {
          final num sum = reviews.fold<num>(0, (acc, e) => acc + ((e['rating'] ?? 0) as num));
          avgRating = (sum / reviews.length).toDouble();
        }
        
        // Get address from public.users table
        final address = user['address']?.toString() ?? 'Location not specified';
        
        return {
          'id': userId,
          'user_id': userId,
          'sitter_id': m['id']?.toString(),
          'name': (user['name'] ?? 'Sitter').toString(),
          'is_available': m['is_available'],
          'rate_per_hour': m['hourly_rate'],
          'bio': m['bio'],
          'experience': m['experience'],
          'rating': avgRating,
          'profile_picture': user['profile_picture'],
          'address': address,
        };
      }).toList();

      // Filter by location if search query is provided
      List<dynamic> filteredSitters = sittersWithAddress;
      if (locationQuery != null && locationQuery.trim().isNotEmpty) {
        final query = locationQuery.toLowerCase().trim();
        final matchingSitters = sittersWithAddress.where((sitter) {
          final address = (sitter['address'] ?? '').toString().toLowerCase();
          // Enable partial matching: "buenavista" matches "Buenavista, Agusan del Norte"
          return address != 'location not specified' && address.contains(query);
        }).toList();
        
        if (matchingSitters.isEmpty && sittersWithAddress.isNotEmpty) {
          // If no sitters match the location, show message but still display all
          if (mounted) {
            _showEnhancedSnackBar('No sitters found in "$locationQuery". Showing all available sitters.');
          }
          filteredSitters = sittersWithAddress;
        } else {
          filteredSitters = matchingSitters;
          // Show success message for location search
          if (mounted && matchingSitters.isNotEmpty) {
            _showEnhancedSnackBar('Found ${matchingSitters.length} sitter(s) in "$locationQuery"');
          }
        }
      }

      setState(() => availableSitters = filteredSitters);
    } catch (e) {
      print('❌ fetchAvailableSitters ERROR: $e');
      if (mounted) {
        _showEnhancedSnackBar('Error loading sitters. Please try again.', isError: true);
      }
    }
  }

  Future<void> fetchOwnedPets() async {
    final petRes = await supabase.from('pets').select().eq('owner_id', widget.userId);
    setState(() => pets = petRes);
    // After we have the owner's pets, fetch any pending sitting requests they created
    await fetchOwnerPendingRequests();
  }

  Future<void> fetchOwnerPendingRequests() async {
    try {
      if (pets.isEmpty) {
        setState(() {
          ownerPendingRequests = [];
          pendingSitterIds = {};
        });
        return;
      }

      // Build pet_id list owned by the user
      final petIds = pets
          .map((p) => p['id'])
          .where((id) => id != null && id.toString().isNotEmpty)
          .map<String>((id) => id.toString())
          .toList();

      if (petIds.isEmpty) {
        setState(() {
          ownerPendingRequests = [];
          pendingSitterIds = {};
        });
        return;
      }

      // Query A: filter by pet_id IN (...) + status = Pending
      final a = await supabase
          .from('sitting_jobs')
          .select('id, sitter_id, pet_id, status, created_at')
          .eq('status', 'Pending')
          .inFilter('pet_id', petIds);

      // Query B: inner join pets and filter by pets.owner_id (covers cases where policies rely on join)
      final b = await supabase
          .from('sitting_jobs')
          .select('id, sitter_id, pet_id, status, created_at, pets!inner(id, owner_id)')
          .eq('status', 'Pending')
          .eq('pets.owner_id', widget.userId);

      // Merge and dedupe by id
      final List<dynamic> listA = (a as List?) ?? [];
      final List<dynamic> listB = (b as List?) ?? [];
      final Map<String, Map<String, dynamic>> byId = {};
      for (final row in [...listA, ...listB]) {
        final id = row['id']?.toString();
        if (id != null && id.isNotEmpty) {
          byId[id] = Map<String, dynamic>.from(row as Map);
        }
      }
      final merged = byId.values.toList();

      setState(() {
        ownerPendingRequests = merged;
        pendingSitterIds = merged
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
    final jobsRes = await supabase
        .from('sitting_jobs_with_owner')
        .select('id, status, start_date, end_date, pet_name, pet_type, owner_name, owner_id')
        .eq('sitter_id', widget.userId)
        .neq('status', 'Cancelled') // exclude declined/cancelled jobs from Assigned Jobs
        .order('start_date', ascending: false);

    // Compute completed jobs count from fetched jobs
    final completed = (jobsRes as List)
        .where((j) => (j['status'] ?? '').toString().toLowerCase() == 'completed')
        .length;

    setState(() {
      sittingJobs = jobsRes;
      completedJobsCount = completed;
    });
  }

  // NEW: fetch latest sitter reviews
  Future<void> fetchSitterReviews() async {
    try {
      // Try resolving sitters.id from current user's id (works when accessible)
      final sitterId = await _resolveSitterIdForReview(widget.userId);

      if (sitterId != null) {
        final res = await supabase
            .from('sitter_reviews')
            .select()
            .eq('sitter_id', sitterId)
            .order('created_at', ascending: false)
            .limit(10);
        setState(() => sitterReviews = res ?? []);
        return;
      }

      // Fallback: join sitter_reviews -> sitters and filter by sitters.user_id
      // Useful when direct reads to sitters are restricted by RLS.
      final fallback = await supabase
          .from('sitter_reviews')
          .select('id, rating, comment, created_at, owner_name, sitters!inner(user_id)')
          .eq('sitters.user_id', widget.userId)
          .order('created_at', ascending: false)
          .limit(10);
      setState(() => sitterReviews = fallback ?? []);
    } catch (e) {
      print('❌ fetchSitterReviews ERROR: $e');
      setState(() => sitterReviews = []);
    }
  }

  Future<void> fetchDailySummary() async {
    try {
      final summaryRes = await supabase
          .from('behavior_logs')
          .select()
          .eq('user_id', widget.userId)
          .order('log_date', ascending: false)
          .limit(1)
          .maybeSingle();
      if (summaryRes != null) {
        setState(() => summary = summaryRes);
      }
    } catch (_) {}
  }

  // Fetch reviews for a sitter by their users.id (resolves to sitters.id, with join fallback)
  Future<List<dynamic>> _fetchReviewsForSitterUser(String sitterUserId) async {
    try {
      final sitterId = await _resolveSitterIdForReview(sitterUserId);
      if (sitterId != null) {
        final res = await supabase
            .from('sitter_reviews')
            .select()
            .eq('sitter_id', sitterId)
            .order('created_at', ascending: false)
            .limit(20);
        return (res as List?) ?? [];
      }
      // Fallback join via sitters.user_id
      final res = await supabase
          .from('sitter_reviews')
          .select('id, rating, comment, created_at, owner_name, sitters!inner(user_id)')
          .eq('sitters.user_id', sitterUserId)
          .order('created_at', ascending: false)
          .limit(20);
      return (res as List?) ?? [];
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
                        Container(
                          padding: EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 20,
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

  // Realtime: listen for INSERT/UPDATE/DELETE on sitting_jobs and refresh view when relevant
  void _setupRealtime() {
    _jobsChannel?.unsubscribe();
    _jobsChannel = supabase
        .channel('sitting_jobs_${widget.userId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'sitting_jobs',
          callback: (payload) {
            final newRow = payload.newRecord as Map<String, dynamic>?;
            final oldRow = payload.oldRecord as Map<String, dynamic>?;
            final row = newRow ?? oldRow;
            if (row == null) return;

            final sitterMatches = (row['sitter_id']?.toString() ?? '') == widget.userId;
            final jobPetId = row['pet_id']?.toString();
            final ownerMatches = jobPetId != null && pets.any((p) => p['id']?.toString() == jobPetId);

            if (sitterMatches || ownerMatches) {
              // Fetch the latest data segments that could be affected
              fetchSittingJobs();
              fetchOwnerPendingRequests();
              fetchOwnerActiveJobs();
            }
          },
        )
        .subscribe();
  }

  // Update job status: return updated row (if allowed) and patch UI safely
  Future<void> _updateJobStatus(String jobId, String status) async {
    try {
      final update = <String, dynamic>{'status': status};
      if (status == 'Active') {
        update['start_date'] = DateTime.now().toIso8601String().substring(0, 10);
      }
      if (status == 'Completed') {
        update['end_date'] = DateTime.now().toIso8601String().substring(0, 10);
      }

      // Perform update without select() to avoid PostgREST single-object errors on 0 rows
      await supabase.from('sitting_jobs').update(update).eq('id', jobId);

      // Optimistically patch local UI
      setState(() {
        final idx = sittingJobs.indexWhere((j) => j['id']?.toString() == jobId);
        if (idx != -1) {
          if (status == 'Cancelled') {
            sittingJobs.removeAt(idx);
          } else {
            sittingJobs[idx] = { ...sittingJobs[idx], ...update, 'id': jobId };
          }
        }
        completedJobsCount = sittingJobs
            .where((j) => (j['status'] ?? '').toString().toLowerCase() == 'completed')
            .length;
      });

      // Refresh lists to stay in sync with backend/RLS
      await Future.wait([
        fetchSittingJobs(),
        fetchOwnerPendingRequests(),
        fetchOwnerActiveJobs(),
      ]);

      if (mounted) {
        _showEnhancedSnackBar('Job $status.');
      }
    } catch (e) {
      if (mounted) {
        _showEnhancedSnackBar('Failed to update: $e', isError: true);
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

  // Enhanced Hire modal with modern design
  Future<void> _showHireModal(Map<String, dynamic> sitter) async {
    if (pets.isEmpty) {
      _showEnhancedSnackBar('You have no pets. Add a pet before hiring a sitter.', isError: true);
      return;
    }

    String? selectedPetId = pets.isNotEmpty ? pets.first['id'] as String? : null;

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
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.pets,
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
                                    'Hire Sitter',
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
                                  Container(
                                    width: 50,
                                    height: 50,
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
                                        (sitter['name'] ?? 'S')[0].toUpperCase(),
                                        style: TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                          fontFamily: 'Roboto',
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          sitter['name'] ?? 'Sitter',
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
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: coral.withOpacity(0.3)),
                              ),
                              child: DropdownButtonFormField<String>(
                                value: selectedPetId,
                                items: pets.map<DropdownMenuItem<String>>((p) {
                                  return DropdownMenuItem(
                                    value: p['id'] as String?,
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 30,
                                          height: 30,
                                          decoration: BoxDecoration(
                                            color: peach.withOpacity(0.3),
                                            shape: BoxShape.circle,
                                          ),
                                          child: Icon(
                                            Icons.pets,
                                            size: 16,
                                            color: coral,
                                          ),
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
                                onChanged: (v) => setModalState(() => selectedPetId = v),
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
                                      foregroundColor: coral,
                                      side: BorderSide(color: coral),
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
                                      backgroundColor: deepRed,
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
      await supabase.from('sitting_jobs').insert(payload);
      setState(() {
        pendingSitterIds.add(sitterId);
      });
      _showEnhancedSnackBar('Sitter hired — request sent.');
      await Future.wait([fetchOwnerPendingRequests(), fetchOwnerActiveJobs()]);
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
      final petIds = pets
          .map((p) => p['id'])
          .where((id) => id != null && id.toString().isNotEmpty)
          .map<String>((id) => id.toString())
          .toList();
      if (petIds.isEmpty) {
        setState(() => ownerActiveJobs = []);
        return;
      }

      // Include pets(name) so we can display the pet's name in the UI
      final a = await supabase
          .from('sitting_jobs')
          .select('id, sitter_id, pet_id, status, start_date, end_date, created_at, pets(name)')
          .eq('status', 'Active')
          .inFilter('pet_id', petIds);

      final b = await supabase
          .from('sitting_jobs')
          .select('id, sitter_id, pet_id, status, start_date, end_date, created_at, pets!inner(id, owner_id, name)')
          .eq('status', 'Active')
          .eq('pets.owner_id', widget.userId);

      final List<dynamic> listA = (a as List?) ?? [];
      final List<dynamic> listB = (b as List?) ?? [];
      final Map<String, Map<String, dynamic>> byId = {};
      for (final row in [...listA, ...listB]) {
        final id = row['id']?.toString();
        if (id != null && id.isNotEmpty) {
          // FIX: properly cast row to Map<String, dynamic>
          byId[id] = Map<String, dynamic>.from(row as Map);
        }
      }
      setState(() => ownerActiveJobs = byId.values.toList());
    } catch (e) {
      print('❌ fetchOwnerActiveJobs ERROR: $e');
    }
  }

  // Enhanced modal to finish job and add a review
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
                                    'Caring for $petName',
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
                                  Center(
                                    child: Text(
                                      '${rating.round()} out of 5 stars',
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
                                        Icons.comment,
                                        color: coral,
                                        size: 20,
                                      ),
                                      SizedBox(width: 8),
                                      Text(
                                        'Leave a comment (optional)',
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
                                      hintText: 'Tell others about your experience...',
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
                                    onChanged: (v) => setModalState(() => comment = v),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(height: 30),
                            
                            // Action buttons
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () => Navigator.of(ctx).pop(),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: coral,
                                      side: BorderSide(color: coral),
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
                                      ),
                                    ),
                                  ),
                                ),
                                SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: deepRed,
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

                                        // 2) sitter_reviews.sitter_id must be sitters.id.
                                        final sitterUserId = job['sitter_id']?.toString();
                                        final sitterIdForReview = sitterUserId == null
                                            ? null
                                            : await _resolveSitterIdForReview(sitterUserId);

                                        if (sitterIdForReview == null) {
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

                                        // Force integer rating and request the inserted id back for verification.
                                        await supabase
                                            .from('sitter_reviews')
                                            .insert({
                                              'sitter_id': sitterIdForReview,
                                              'reviewer_id': widget.userId,                    // users.id (uuid)
                                              'rating': rating.round(),                        // strict int 1..5
                                              'comment': comment.trim().isEmpty ? null : comment.trim(),
                                              'owner_name': (userName.isEmpty ? 'Pet Owner' : userName),
                                            })
                                            .select('id')
                                            .single();

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

  // Resolve sitter_id for sitter_reviews FK.
  // Accepts either a users.id (preferred) or a sitters.id and returns sitters.id.
  Future<String?> _resolveSitterIdForReview(String sitterIdentifier) async {
    try {
      // Prefer mapping from user_id -> sitters.id
      final viaUser = await supabase
          .from('sitters')
          .select('id')
          .eq('user_id', sitterIdentifier)
          .maybeSingle();
      if (viaUser != null && viaUser['id'] != null) {
        return viaUser['id'].toString();
      }

      // If the identifier is already a sitters.id, allow it
      final viaId = await supabase
          .from('sitters')
          .select('id')
          .eq('id', sitterIdentifier)
          .maybeSingle();
      if (viaId != null && viaId['id'] != null) {
        return viaId['id'].toString();
      }
    } catch (_) {}
    return null; // explicit null so callers can handle properly
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

  // Small stat chip used by owner's summary section
  Widget _ownerStatChip({
    required IconData icon,
    required String label,
    required String value,
    Color? bg,
    Color? fg,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      margin: EdgeInsets.only(right: 8, bottom: 8),
      decoration: BoxDecoration(
        color: (bg ?? Colors.white),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: fg ?? deepRed, size: 18),
          SizedBox(width: 8),
          Text(value, style: TextStyle(fontWeight: FontWeight.bold, color: fg ?? deepRed, fontFamily: 'Roboto')),
          SizedBox(width: 6),
          Text(label, style: TextStyle(color: (fg ?? deepRed).withOpacity(0.8), fontFamily: 'Roboto')),
        ],
      ),
      );
  }

  // Owner: Summary chips (Pets, Pending Requests, Available Now)
  Widget _buildOwnerSummaryChips() {
    final petsCount = pets.length;
    final pendingCount = ownerPendingRequests.length;
    final availableNow = availableSitters.where((s) => (s['is_available'] == true)).length;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: _ownerStatChip(
            icon: Icons.pets,
            label: 'Pets',
            value: '$petsCount',
            bg: Colors.white,
            fg: deepRed,
          ),
        ),
        Expanded(
          child: Center(
            child: _ownerStatChip(
              icon: Icons.hourglass_top,
              label: 'Pending',
              value: '$pendingCount',
              bg: Colors.white,
              fg: Colors.orange[800],
            ),
          ),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: _ownerStatChip(
              icon: Icons.person_pin_circle,
              label: 'Available',
              value: '$availableNow',
              bg: Colors.white,
              fg: Colors.green[800],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOwnerHome() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // New greeting and summary for owners
        _buildOwnerGreeting(),
        SizedBox(height: 12),
        _buildOwnerSummaryChips(),
        SizedBox(height: 16),

        // Search bar stays, below the greeting/summary
        TextField(
          controller: _locationSearchController,
          decoration: InputDecoration(
            hintText: 'Search Sitters by Location',
            prefixIcon: Icon(Icons.search),
            suffixIcon: _currentSearchQuery.isNotEmpty 
                ? IconButton(
                    icon: Icon(Icons.clear),
                    onPressed: _clearSearch,
                  )
                : null,
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
          onSubmitted: _performSearch,
          onChanged: (value) {
            // Optional: perform search as user types (debounced)
            if (value.isEmpty && _currentSearchQuery.isNotEmpty) {
              _clearSearch();
            }
          },
        ),
        SizedBox(height: 16),

        // New: Owner Active Jobs section with Finish button
        _sectionWithBorder(
          title: "Active Jobs",
          child: ownerActiveJobs.isEmpty
              ? Text('No active jobs right now.', style: TextStyle(color: Colors.grey[700], fontFamily: 'Roboto'))
              : Column(
                  children: ownerActiveJobs.map((job) {
                    final petName = (job['pets']?['name'] ?? job['pet_id'] ?? 'Pet').toString();
                    final start = (job['start_date'] ?? '').toString();
                    return Card(
                      margin: EdgeInsets.symmetric(vertical: 6),
                      child: ListTile(
                        leading: Icon(Icons.pets, color: deepRed),
                        title: Text('Pet: $petName', style: TextStyle(fontFamily: 'Roboto')),
                        subtitle: Text('Started: ${start.isEmpty ? '-' : start}', style: TextStyle(fontFamily: 'Roboto')),
                        trailing: ElevatedButton(
                          onPressed: () => _showFinishJobModal(job),
                          style: ElevatedButton.styleFrom(backgroundColor: deepRed, foregroundColor: Colors.white),
                          child: Text('Mark Finished', style: TextStyle(fontFamily: 'Roboto')),
                        ),
                      ),
                    );
                  }).toList(),
                ),
        ),

        SizedBox(height: 16),

        // ...existing code... (TabBar + TabBarView)
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
                    // Available Now = is_available true from DB
                    _buildSitterList(
                      availableSitters.where((s) => s['is_available'] == true).toList(),
                    ),
                    // Top Rated = avg rating >= 4.5 (nulls excluded)
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
                                          Icons.payments,
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
                                  : deepRed,
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

        // NEW: Availability switch
        Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          elevation: 2,
          child: SwitchListTile(
            title: Text('Available for jobs', style: TextStyle(fontWeight: FontWeight.w600, color: deepRed, fontFamily: 'Roboto')),
            subtitle: Text(
              (_isSitterAvailable ?? false) ? 'Owners can see and hire you' : 'You appear as busy',
              style: TextStyle(color: Colors.grey[700]),
            ),
            secondary: Icon(
              (_isSitterAvailable ?? false) ? Icons.check_circle : Icons.cancel,
              color: (_isSitterAvailable ?? false) ? Colors.green[700] : Colors.red[700],
            ),
            value: _isSitterAvailable ?? false,
            onChanged: (_isSitterAvailable == null || _isUpdatingAvailability) ? null : (v) => _setSitterAvailability(v),
          ),
        ),

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

        // NEW: Profile summary
        if (_sitterProfile != null)
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your Profile', style: TextStyle(fontWeight: FontWeight.bold, color: deepRed, fontFamily: 'Roboto')),
                  SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Experience', style: TextStyle(color: Colors.grey[600], fontFamily: 'Roboto')),
                            Text(
                              _sitterProfile!['experience'] != null 
                                  ? '${_sitterProfile!['experience']} years' 
                                  : 'Not set',
                              style: TextStyle(fontWeight: FontWeight.w600, fontFamily: 'Roboto'),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Hourly Rate', style: TextStyle(color: Colors.grey[600], fontFamily: 'Roboto')),
                            Text(
                              _sitterProfile!['hourly_rate'] != null 
                                  ? '₱ ${_sitterProfile!['hourly_rate']}/hr' 
                                  : 'Not set',
                              style: TextStyle(fontWeight: FontWeight.w600, color: Colors.green[700], fontFamily: 'Roboto'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (_sitterProfile!['bio'] != null && _sitterProfile!['bio'].toString().isNotEmpty) ...[
                    SizedBox(height: 12),
                    Text('Bio', style: TextStyle(color: Colors.grey[600], fontFamily: 'Roboto')),
                    Text(
                      _sitterProfile!['bio'].toString(),
                      style: TextStyle(fontFamily: 'Roboto'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ),

        SizedBox(height: 16),

        // ✅ Assigned Jobs
        _sectionWithBorder(
          title: "Assigned Jobs",
          child: Column(
            children: [
              // Filter controls
              Row(
                children: [
                  Text('Filter:', style: TextStyle(color: deepRed, fontWeight: FontWeight.w600, fontFamily: 'Roboto')),
                  SizedBox(width: 8),
                  DropdownButton<String>(
                    value: _jobsStatusFilter,
                    items: _jobStatusOptions
                        .map((o) => DropdownMenuItem<String>(value: o, child: Text(o, style: TextStyle(fontFamily: 'Roboto'))))
                        .toList(),
                    onChanged: (v) => setState(() => _jobsStatusFilter = v ?? 'All'),
                  ),
                ],
              ),
              SizedBox(height: 8),

              // Apply filter to jobs
              Builder(builder: (context) {
                final sel = _jobsStatusFilter.toLowerCase();
                final filtered = _jobsStatusFilter == 'All'
                    ? sittingJobs
                    : sittingJobs.where((j) => (j['status'] ?? '').toString().toLowerCase() == sel).toList();

                if (filtered.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('No jobs for selected filter.', style: TextStyle(color: Colors.grey[700], fontFamily: 'Roboto')),
                  );
                }

                return Column(
                  // Replace: sittingJobs.take(3) -> filtered (show all matching)
                  children: filtered.map((job) {
                    final petName = job['pet_name'] ?? 'Pet';
                    final petType = job['pet_type'] ?? 'Pet';
                    final startTime = job['start_date'] ?? 'Time not set';
                    final endTime = job['end_date'] ?? 'Time not set';
                    final status = (job['status'] ?? 'Pending').toString();
                    final ownerName = job['owner_name'] ?? 'Owner';
                    final String? ownerId = job['owner_id'] as String?;
                    final String jobId = job['id'].toString();

                    return Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 3,
                      margin: EdgeInsets.symmetric(vertical: 6),
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          children: [
                            ListTile(
                              leading: Icon(Icons.pets, color: deepRed),
                              title: Text('Owner: $ownerName\n$petName ($petType)', style: TextStyle(fontFamily: 'Roboto')),
                              subtitle: Text('Start: $startTime\nEnd: $endTime', style: TextStyle(fontFamily: 'Roboto')),
                              trailing: Container(
                                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: status == 'Active'
                                      ? Colors.green.withOpacity(0.15)
                                      : status == 'Cancelled'
                                          ? Colors.red.withOpacity(0.15)
                                          : status == 'Completed'
                                              ? Colors.blue.withOpacity(0.15)
                                              : Colors.orange.withOpacity(0.15),
                                ),
                                child: Text(
                                  status,
                                  style: TextStyle(
                                    color: status == 'Active'
                                        ? Colors.green[800]
                                        : status == 'Cancelled'
                                            ? Colors.red[800]
                                            : status == 'Completed'
                                                ? Colors.blue[800]
                                                : Colors.orange[800],
                                    fontWeight: FontWeight.w600,
                                    fontFamily: 'Roboto',
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(height: 4),
                            if (status == 'Pending')
                              Row(
                                children: [
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () => _updateJobStatus(jobId, 'Active'),
                                      icon: Icon(Icons.check),
                                      label: Text('Accept', style: TextStyle(fontFamily: 'Roboto')),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: deepRed,
                                        foregroundColor: Colors.white,
                                      ),
                                    ),
                                  ),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () => _updateJobStatus(jobId, 'Cancelled'),
                                      icon: Icon(Icons.close, color: deepRed),
                                      label: Text('Decline', style: TextStyle(color: deepRed, fontFamily: 'Roboto')),
                                      style: OutlinedButton.styleFrom(side: BorderSide(color: deepRed)),
                                    ),
                                  ),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: ownerId != null
                                          ? () => _openChatWithOwner(ownerId, ownerName: ownerName)
                                          : null,
                                      icon: Icon(Icons.message),
                                      label: Text('Chat', style: TextStyle(fontFamily: 'Roboto')),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: coral,
                                        foregroundColor: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            else
                              Align(
                                alignment: Alignment.centerRight,
                                child: SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    onPressed: ownerId != null
                                        ? () => _openChatWithOwner(ownerId, ownerName: ownerName)
                                        : null,
                                    icon: Icon(Icons.message),
                                    label: Text('Chat', style: TextStyle(fontFamily: 'Roboto')),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: coral,
                                      foregroundColor: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                );
              }),
            ],
          ),
        ),

        SizedBox(height: 24),

        // ⭐ Reviews (data-driven)
        _sectionWithBorder(
          title: "Reviews",
          child: SizedBox(
            height: 160,
            child: sitterReviews.isEmpty
                ? Center(child: Text('No reviews yet', style: TextStyle(color: Colors.grey[600], fontFamily: 'Roboto')))
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: sitterReviews.length,
                    separatorBuilder: (_, __) => SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final rev = sitterReviews[index] as Map<String, dynamic>;
                      return _buildReviewCardFromData(rev);
                    },
                  ),
          ),
        ),

        SizedBox(height: 24),

        // 🧾 Completed Jobs (data-driven)
        _sectionWithBorder(
          title: "Completed Jobs",
          child: Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green[700]),
                    SizedBox(width: 8),
                    Text(
                      "$completedJobsCount",
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green[800], fontFamily: 'Roboto'),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  completedJobsCount == 1
                      ? "You’ve completed 1 job"
                      : "You’ve completed $completedJobsCount jobs",
                  style: TextStyle(fontSize: 16, color: deepRed, fontFamily: 'Roboto'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Replace the old dummy card builder with a data-driven one
  Widget _buildReviewCardFromData(Map<String, dynamic> review) {
    final ratingNum = (review['rating'] is num) ? (review['rating'] as num).toDouble() : 0.0;
    final comment = (review['comment'] ?? '').toString();
    final owner = (review['owner_name'] ?? 'Pet Owner').toString();

    return Container(
      width: 260,
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: _buildRatingStars(ratingNum)),
          SizedBox(height: 8),
          Text(
            comment.isEmpty ? "(No comment)" : '"$comment"',
            style: TextStyle(fontStyle: FontStyle.italic, fontFamily: 'Roboto'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          SizedBox(height: 8),
          Text('– $owner', style: TextStyle(color: Colors.grey[600], fontFamily: 'Roboto')),
        ],
      ),
    );
  }

  // Enhanced review card for modal display
  Widget _buildEnhancedReviewCard(Map<String, dynamic> review) {
    final ratingNum = (review['rating'] is num) ? (review['rating'] as num).toDouble() : 0.0;
    final comment = (review['comment'] ?? '').toString();
    final owner = (review['owner_name'] ?? 'Pet Owner').toString();
    final createdAt = review['created_at']?.toString();
    
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
          // Header with rating and time
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(children: _buildRatingStars(ratingNum)),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: coral.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  timeAgo,
                  style: TextStyle(
                    fontSize: 12,
                    color: coral,
                    fontWeight: FontWeight.w500,
                    fontFamily: 'Roboto',
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          
          // Comment
          if (comment.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: lightBlush.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: peach.withOpacity(0.3)),
              ),
              child: Text(
                '"$comment"',
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  fontSize: 14,
                  color: Colors.grey[700],
                  fontFamily: 'Roboto',
                  height: 1.4,
                ),
              ),
            ),
            SizedBox(height: 12),
          ],
          
          // Owner info
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
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
                    owner.isNotEmpty ? owner[0].toUpperCase() : 'O',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontFamily: 'Roboto',
                    ),
                  ),
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      owner,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: deepRed,
                        fontFamily: 'Roboto',
                      ),
                    ),
                    Text(
                      'Pet Owner',
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

  Widget _sectionWithBorder({required String title, required Widget child}) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(title),
          SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: coral, fontFamily: 'Roboto'));
  }

  // NEW: load sitter availability from sitters by user_id
  Future<void> fetchSitterAvailability() async {
    try {
      final row = await supabase
          .from('sitters')
          .select('is_available')
          .eq('user_id', widget.userId)
          .maybeSingle();
      setState(() => _isSitterAvailable = (row?['is_available'] == true));
    } catch (e) {
      print('❌ fetchSitterAvailability ERROR: $e');
      setState(() => _isSitterAvailable = false);
    }
  }

  // NEW: fetch sitter profile data
  Future<void> fetchSitterProfile() async {
    try {
      final row = await supabase
          .from('sitters')
          .select('id, bio, experience, hourly_rate, is_available')
          .eq('user_id', widget.userId)
          .maybeSingle();
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

      await supabase
          .from('sitters')
          .update(updates)
          .eq('user_id', widget.userId);

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
      await supabase.from('sitters').update({'is_available': value}).eq('user_id', widget.userId);
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
                                              Icons.payments,
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
                                      foregroundColor: coral,
                                      side: BorderSide(color: coral),
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
                                      backgroundColor: deepRed,
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

  Widget _buildDefaultAvatar(String name) {
    return Container(
      width: 54,
      height: 54,
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