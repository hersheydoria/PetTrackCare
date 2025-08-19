import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:PetTrackCare/screens/calendar_screen.dart';
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
      final sitters = await supabase.from('users').select().eq('role', 'Pet Sitter');
      setState(() => availableSitters = sitters);
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
      final res = await supabase
          .from('sitter_reviews')
          .select()
          .eq('sitter_id', widget.userId)
          .order('created_at', ascending: false)
          .limit(10);
      setState(() => sitterReviews = res ?? []);
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
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: deepRed),
                    ),
                    SizedBox(height: 8),
                    Divider(),
                    SizedBox(height: 8),
                    Text('Select which pet this sitter will look after:', style: TextStyle(color: deepRed)),
                    SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: selectedPetId,
                      items: pets.map<DropdownMenuItem<String>>((p) {
                        return DropdownMenuItem(value: p['id'] as String?, child: Text(p['name'] ?? 'Unnamed'));
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
                        child: Text('Confirm Hire'),
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
              Text('Finish Job & Review', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: deepRed)),
              SizedBox(height: 12),
              Row(
                children: [
                  Text('Rating:', style: TextStyle(color: deepRed)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Slider(
                      min: 1, max: 5, divisions: 4, // integer steps only
                      label: rating.round().toString(),
                      value: rating,
                      onChanged: (v) => setState(() => rating = v),
                    ),
                  ),
                  Text(rating.round().toString()),
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
                onChanged: (v) => comment = v,
              ),
              SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: deepRed),
                  onPressed: () async {
                    // Close the modal immediately
                    Navigator.of(ctx).pop();
                    try {
                      // 1) complete job
                      await _updateJobStatus(job['id'].toString(), 'Completed');

                      // 2) resolve sitter_id for FK and insert review with integer rating + reviewer_id
                      final sitterIdForReview = await _resolveSitterIdForReview(job['sitter_id'].toString());
                      await supabase.from('sitter_reviews').insert({
                        'sitter_id': sitterIdForReview,
                        'reviewer_id': widget.userId,
                        'rating': rating.round(),
                        'comment': comment.isEmpty ? null : comment,
                        'owner_name': userName,
                      });

                      await fetchOwnerActiveJobs();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Job finished and review posted.')),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Finish failed: $e')),
                        );
                      }
                    }
                  },
                  child: Text('Submit'),
                ),
              ),
              SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  // Resolve sitter_id for sitter_reviews FK (tries sitters.id then sitters.user_id)
  Future<String> _resolveSitterIdForReview(String sitterId) async {
    try {
      final s1 = await supabase.from('sitters').select('id').eq('id', sitterId).maybeSingle();
      if (s1 != null && s1['id'] != null) return s1['id'].toString();
      final s2 = await supabase.from('sitters').select('id').eq('user_id', sitterId).maybeSingle();
      if (s2 != null && s2['id'] != null) return s2['id'].toString();
    } catch (_) {}
    return sitterId; // fallback
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
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  "Your sitter dashboard is ready.",
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 14,
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
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  "Find trusted sitters and manage your requests.",
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 14,
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
          Text(value, style: TextStyle(fontWeight: FontWeight.bold, color: fg ?? deepRed)),
          SizedBox(width: 6),
          Text(label, style: TextStyle(color: (fg ?? deepRed).withOpacity(0.8))),
        ],
      ),
      );
  }

  // Owner: Summary chips (Pets, Pending Requests, Available Now)
  Widget _buildOwnerSummaryChips() {
    final petsCount = pets.length;
    final pendingCount = ownerPendingRequests.length;
    final availableNow = availableSitters.where((s) => (s['is_available'] == true)).length;

    return Wrap(
      children: [
        _ownerStatChip(
          icon: Icons.pets,
          label: 'Pets',
          value: '$petsCount',
          bg: Colors.white,
          fg: deepRed,
        ),
        _ownerStatChip(
          icon: Icons.hourglass_top,
          label: 'Pending',
          value: '$pendingCount',
          bg: Colors.white,
          fg: Colors.orange[800],
        ),
        _ownerStatChip(
          icon: Icons.person_pin_circle,
          label: 'Available',
          value: '$availableNow',
          bg: Colors.white,
          fg: Colors.green[800],
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
              ? Text('No active jobs right now.', style: TextStyle(color: Colors.grey[700]))
              : Column(
                  children: ownerActiveJobs.map((job) {
                    final petName = (job['pets']?['name'] ?? job['pet_id'] ?? 'Pet').toString();
                    final start = (job['start_date'] ?? '').toString();
                    return Card(
                      margin: EdgeInsets.symmetric(vertical: 6),
                      child: ListTile(
                        leading: Icon(Icons.pets, color: deepRed),
                        title: Text('Pet: $petName'),
                        subtitle: Text('Started: ${start.isEmpty ? '-' : start}'),
                        trailing: ElevatedButton(
                          onPressed: () => _showFinishJobModal(job),
                          style: ElevatedButton.styleFrom(backgroundColor: deepRed, foregroundColor: Colors.white),
                          child: Text('Mark Finished'),
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
                    _buildSitterList(availableSitters.where((s) => s['is_available'] == true).toList()),
                    _buildSitterList(availableSitters.where((s) => (s['rating'] ?? 0) >= 4.5).toList()),
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
          return Card(
            margin: EdgeInsets.only(bottom: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16.0), // FIX: add named argument
              child: Column(
                children: [
                  Center(
                    child: Text(
                      sitter['name'] ?? 'Unnamed',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                  ),
                  SizedBox(height: 12),
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 26,
                        backgroundImage: AssetImage('assets/sitter_placeholder.png'),
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
                                Text('${sitter['rating']?.toStringAsFixed(1) ?? '4.5'}'),
                              ],
                            ),
                            Text(
                              'Status: ${sitter['is_available'] == true ? 'Available Now' : 'Busy'}',
                              style: TextStyle(
                                color: sitter['is_available'] == true ? Colors.green[700] : Colors.grey,
                              ),
                            ),
                            Text('Rate: ₱${sitter['rate_per_hour'] ?? 250} / hour'),
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
                          onPressed: () {
                            showModalBottomSheet(
                              context: context,
                              isScrollControlled: true,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                              ),
                              builder: (context) => FractionallySizedBox(
                                heightFactor: 0.85,
                                child: CalendarScreen(sitter: sitter),
                              ),
                            );
                          },
                          icon: Icon(Icons.calendar_today),
                          label: Text('View Schedule'),
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
                            label: Text(isPending ? 'Pending' : 'Hire Sitter'),
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
                          label: Text('Send a Message'),
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
    // derive today’s jobs from sittingJobs (based on start_date)
    final today = DateTime.now();
    final todayStr = "${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}";
    final todaysJobs = sittingJobs.where((job) {
      final sd = job['start_date']?.toString();
      return sd == todayStr;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // REPLACED old header texts with redesigned greeting
        _buildSitterGreeting(),
        SizedBox(height: 24),

        // ✅ Assigned Jobs
        _sectionWithBorder(
          title: "Assigned Jobs",
          child: Column(
            children: sittingJobs.take(3).map((job) {
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
                        title: Text('$petName ($petType)'),
                        subtitle: Text('Start: $startTime'),
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
                            borderRadius: BorderRadius.circular(12),
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
                                label: Text('Accept'),
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
                                label: Text('Decline', style: TextStyle(color: deepRed)),
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
                                label: Text('Chat'),
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
                              label: Text('Chat'),
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
          ),
        ),

        SizedBox(height: 24),

        // ⭐ Reviews (data-driven)
        _sectionWithBorder(
          title: "Reviews",
          child: SizedBox(
            height: 160,
            child: sitterReviews.isEmpty
                ? Center(child: Text('No reviews yet', style: TextStyle(color: Colors.grey[600])))
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

        // 🗓️ Today’s Schedule (data-driven)
        _sectionWithBorder(
          title: "Today’s Schedule",
          child: todaysJobs.isEmpty
              ? Text("No jobs scheduled for today.", style: TextStyle(color: Colors.grey[700]))
              : Column(
                  children: todaysJobs.map((job) {
                    final petName = job['pets']?['name'] ?? 'Pet';
                    final start = job['start_date']?.toString() ?? todayStr;
                    final task = (job['status'] ?? 'Scheduled').toString();
                    return _buildScheduleItem(start, petName, task);
                  }).toList(),
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
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green[800]),
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
                  style: TextStyle(fontSize: 16, color: deepRed),
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
          Expanded(
            child: Text(
              comment.isEmpty ? "(No comment)" : '"$comment"',
              style: TextStyle(fontStyle: FontStyle.italic),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(height: 8),
          Text('– $owner', style: TextStyle(color: Colors.grey[600])),
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
    return Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: coral));
  }

  Widget _buildScheduleItem(String time, String petName, String task) {
    return Container(
      margin: EdgeInsets.symmetric(vertical: 6),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: peach,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text('$time – $petName ($task)', style: TextStyle(color: deepRed)),
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