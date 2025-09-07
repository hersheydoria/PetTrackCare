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

  // Add: jobs filter state
  String _jobsStatusFilter = 'Pending';
  static const List<String> _jobStatusOptions = ['All', 'Pending', 'Active', 'Completed'];

  late TabController _sitterTabController;
  RealtimeChannel? _jobsChannel; // realtime subscription channel

  @override
  void initState() {
    super.initState();
    fetchUserData();
    _sitterTabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _sitterTabController.dispose();
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
        ]);
      } else {
        await Future.wait([
          fetchOwnedPets(),          // will also update pending requests
          fetchAvailableSitters(),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('User profile not found. Please contact support.')),
        );
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

  Future<void> fetchAvailableSitters() async {
    try {
      // Pull from sitters, join users for display name and profile picture, join reviews to compute avg rating
      final rows = await supabase
          .from('sitters')
          .select('id, user_id, is_available, hourly_rate, users!inner(id, name, role, profile_picture), sitter_reviews(rating)')
          .eq('users.role', 'Pet Sitter');

      final List<dynamic> list = (rows as List?) ?? [];
      final mapped = list.map<Map<String, dynamic>>((raw) {
        final m = Map<String, dynamic>.from(raw as Map);
        final user = (m['users'] as Map?) ?? {};
        final reviews = (m['sitter_reviews'] as List?) ?? [];
        double? avgRating;
        if (reviews.isNotEmpty) {
          final num sum = reviews.fold<num>(0, (acc, e) => acc + ((e['rating'] ?? 0) as num));
          avgRating = (sum / reviews.length).toDouble();
        }
        return {
          'id': (user['id'] ?? m['user_id'])?.toString(),
          'user_id': (m['user_id'] ?? user['id'])?.toString(),
          'sitter_id': m['id']?.toString(),
          'name': (user['name'] ?? 'Sitter').toString(),
          'is_available': m['is_available'],
          'rate_per_hour': m['hourly_rate'],
          'rating': avgRating,
          'profile_picture': user['profile_picture'], // <-- add this line
        };
      }).toList();

      setState(() => availableSitters = mapped);
    } catch (e) {
      print('❌ fetchAvailableSitters ERROR: $e');
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
        .from('sitting_jobs')
        // include owner_id to enable "Chat with owner"
        .select('*, pets(name, owner_id, type)')
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Invalid sitter id.')));
      return;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) {
        return FractionallySizedBox(
          heightFactor: 0.7,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(height: 5, width: 60, margin: EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(3))),
                ),
                Text('Reviews for ${sitter['name'] ?? 'Sitter'}',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: deepRed, fontFamily: 'Roboto')),
                SizedBox(height: 12),
                Expanded(
                  child: FutureBuilder<List<dynamic>>(
                    future: _fetchReviewsForSitterUser(sitterUserId),
                    builder: (context, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return Center(child: CircularProgressIndicator(color: deepRed));
                      }
                      final items = snap.data ?? [];
                      if (items.isEmpty) {
                        return Center(child: Text('No reviews yet', style: TextStyle(color: Colors.grey[600], fontFamily: 'Roboto')));
                      }
                      return ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, __) => SizedBox(height: 12),
                        itemBuilder: (_, i) => _buildReviewCardFromData(items[i] as Map<String, dynamic>),
                      );
                    },
                  ),
                ),
              ],
            ),
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Job $status.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update: $e')));
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

  // Simplified Hire modal: remove start/end date selection
  Future<void> _showHireModal(Map<String, dynamic> sitter) async {
    if (pets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('You have no pets. Add a pet before hiring a sitter.')),
      );
      return;
    }

    String? selectedPetId = pets.isNotEmpty ? pets.first['id'] as String? : null;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 16,
                right: 16,
                top: 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        height: 6,
                        width: 60,
                        margin: EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                    Text(
                      'Hire ${sitter['name'] ?? 'Sitter'}',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: deepRed, fontFamily: 'Roboto'),
                    ),
                    SizedBox(height: 8),
                    Divider(),
                    SizedBox(height: 8),
                    Text('Select which pet this sitter will look after:', style: TextStyle(color: deepRed, fontFamily: 'Roboto')),
                    SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: selectedPetId,
                      items: pets.map<DropdownMenuItem<String>>((p) {
                        return DropdownMenuItem(value: p['id'] as String?, child: Text(p['name'] ?? 'Unnamed', style: TextStyle(fontFamily: 'Roboto')));
                      }).toList(),
                      onChanged: (v) => setModalState(() => selectedPetId = v),
                      decoration: InputDecoration(border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
                    ),
                    SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () async {
                          if (selectedPetId == null) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Please select a pet.')));
                            return;
                          }
                          Navigator.of(context).pop();
                          await _createSittingJob(sitter['id'] as String, selectedPetId!);
                        },
                        child: Text('Confirm Hire', style: TextStyle(fontFamily: 'Roboto')),
                        style: ElevatedButton.styleFrom(backgroundColor: deepRed),
                      ),
                    ),
                    SizedBox(height: 12),
                  ],
                ),
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sitter hired — request sent.')));
      await Future.wait([fetchOwnerPendingRequests(), fetchOwnerActiveJobs()]);
    } catch (e) {
      print('❌ createSittingJob ERROR: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to create sitting job.')));
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

  // Modal to finish job and add a quick review
  Future<void> _showFinishJobModal(Map<String, dynamic> job) async {
    double rating = 5;
    String comment = '';
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        // Make the bottom sheet stateful so the Slider works properly
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
                left: 16, right: 16, top: 16,
              ),
              child: Wrap(
                children: [
                  Center(
                    child: Container(height: 5, width: 60, margin: EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(3))),
                  ),
                  Text('Finish Job & Review', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: deepRed, fontFamily: 'Roboto')),
                  SizedBox(height: 12),
                  Row(
                    children: [
                      Text('Rating:', style: TextStyle(color: deepRed, fontFamily: 'Roboto')),
                      SizedBox(width: 8),
                      Expanded(
                        child: Slider(
                          min: 1, max: 5, divisions: 4,
                          label: rating.round().toString(),
                          value: rating,
                          onChanged: (v) => setModalState(() => rating = v),
                        ),
                      ),
                      Text(rating.round().toString(), style: TextStyle(fontFamily: 'Roboto')),
                    ],
                  ),
                  SizedBox(height: 8),
                  TextField(
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: 'Optional comment',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      filled: true, fillColor: Colors.white,
                    ),
                    style: TextStyle(fontFamily: 'Roboto'),
                    onChanged: (v) => setModalState(() => comment = v),
                  ),
                  SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: deepRed),
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
                                SnackBar(content: Text('Cannot post review: sitter profile not found.')),
                              );
                            }
                            return;
                          }

                          // Force integer rating and request the inserted id back for verification.
                          final inserted = await supabase
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
                            final id = (inserted is Map && inserted['id'] != null) ? inserted['id'].toString() : '';
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(id.isEmpty ? 'Job finished and review posted.' : 'Review posted (id: $id).')),
                            );
                          }
                        } catch (e) {
                          // Show detailed error for easier debugging (e.g., FK violations, privileges)
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Finish failed: $e')),
                            );
                          }
                          print('❌ Review insert failed: $e');
                        }
                      },
                      child: Text('Submit', style: TextStyle(fontFamily: 'Roboto')),
                    ),
                  ),
                  SizedBox(height: 12),
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
          decoration: InputDecoration(
            hintText: 'Search Sitters by Location',
            prefixIcon: Icon(Icons.search),
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
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

  Widget _buildSitterList(List<dynamic> sitters) {
    return RefreshIndicator(
      onRefresh: _refreshAll,
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

          return Card(
            margin: EdgeInsets.only(bottom: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Center(
                    child: Text(
                      sitter['name'] ?? 'Unnamed',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, fontFamily: 'Roboto'),
                    ),
                  ),
                  SizedBox(height: 12),
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 26,
                        backgroundImage: profilePic != null && profilePic.isNotEmpty
                            ? NetworkImage(profilePic)
                            : AssetImage('assets/sitter_placeholder.png') as ImageProvider,
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.star, color: Colors.orange, size: 18),
                                SizedBox(width: 4),
                                Text(ratingNum == null ? '—' : ratingNum.toStringAsFixed(1), style: TextStyle(fontFamily: 'Roboto')),
                              ],
                            ),
                            Text(
                              'Status: ${isAvail ? 'Available Now' : 'Busy'}',
                              style: TextStyle(color: isAvail ? Colors.green[700] : Colors.grey, fontFamily: 'Roboto'),
                            ),
                            Text(
                              rateVal == null
                                  ? 'Rate: —'
                                  : 'Rate: ₱${(rateVal is num) ? rateVal.toStringAsFixed(2) : rateVal.toString()} / hour',
                              style: TextStyle(fontFamily: 'Roboto'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  Column(
                    children: [
                      SizedBox(
                        width: 180,
                        child: ElevatedButton.icon(
                          onPressed: () => _showSitterReviewsModal(sitter),
                          icon: Icon(Icons.reviews),
                          label: Text('View Reviews', style: TextStyle(fontFamily: 'Roboto')),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: deepRed,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: 8),
                      SizedBox(
                        width: 180,
                        child: Builder(builder: (context) {
                          final sitterId = sitter['id'] as String?;
                          final isPending = sitterId != null && pendingSitterIds.contains(sitterId);
                          return ElevatedButton.icon(
                            onPressed: isPending ? null : () => _showHireModal(sitter),
                            icon: Icon(isPending ? Icons.hourglass_top : Icons.person_add),
                            label: Text(isPending ? 'Pending' : 'Hire Sitter', style: TextStyle(fontFamily: 'Roboto')),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isPending ? Colors.grey : deepRed,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          );
                        }),
                      ),
                      SizedBox(height: 8),
                      SizedBox(
                        width: 180,
                        child: ElevatedButton.icon(
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
                          icon: Icon(Icons.message),
                          label: Text('Send a Message', style: TextStyle(fontFamily: 'Roboto')),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: deepRed,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
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
                    final petName = job['pets']?['name'] ?? 'Pet';
                    final petType = job['pets']?['type'] ?? 'Pet';
                    final startTime = job['start_date'] ?? 'Time not set';
                    final status = (job['status'] ?? 'Pending').toString();
                    final String? ownerId = job['pets']?['owner_id'] as String?;
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
                              title: Text('$petName ($petType)', style: TextStyle(fontFamily: 'Roboto')),
                              subtitle: Text('Start: $startTime', style: TextStyle(fontFamily: 'Roboto')),
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
                                          ? () => _openChatWithOwner(ownerId, ownerName: 'Owner')
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
                                        ? () => _openChatWithOwner(ownerId, ownerName: 'Owner')
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(value ? 'You are now Available.' : 'You are now Busy.')),
        );
      }
    } catch (e) {
      // revert on failure
      setState(() => _isSitterAvailable = !value);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update availability: $e')));
      }
    } finally {
      if (mounted) setState(() => _isUpdatingAvailability = false);
    }
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