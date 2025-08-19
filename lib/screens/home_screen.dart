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
  Set<String> pendingSitterIds = {};
  Map<String, dynamic> summary = {};

  bool isLoading = true;

  late TabController _sitterTabController;

  @override
  void initState() {
    super.initState();
    fetchUserData();
    _sitterTabController = TabController(length: 3, vsync: this);
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
        ]);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _sitterTabController.dispose();
    super.dispose();
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
        if (userRole == 'Pet Owner') fetchOwnedPets(),
        if (userRole == 'Pet Owner') fetchAvailableSitters(),
        fetchDailySummary()
      ]);

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

      // Query sitting_jobs and include pets; filter on the related pet's owner_id
      final reqs = await supabase
        .from('sitting_jobs')
        .select('*, pets(owner_id)')
        .eq('status', 'Pending')
        .eq('pets.owner_id', widget.userId);

      setState(() {
        ownerPendingRequests = reqs ?? [];
        pendingSitterIds = ownerPendingRequests.map((r) => r['sitter_id'] as String).toSet();
      });
    } catch (e) {
      print('❌ fetchOwnerPendingRequests ERROR: $e');
    }
  }

  Future<void> fetchSittingJobs() async {
    final jobsRes = await supabase
        .from('sitting_jobs')
        // include owner_id to enable "Chat with owner"
        .select('*, pets(name, owner_id)')
        .eq('sitter_id', widget.userId)
        .order('start_date', ascending: false);
    setState(() => sittingJobs = jobsRes);
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

  // Update job status (Accept/Decline)
  Future<void> _updateJobStatus(String jobId, String status) async {
    try {
      await supabase.from('sitting_jobs').update({'status': status}).eq('id', jobId);
      await fetchSittingJobs();
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

  Future<void> _showHireModal(Map<String, dynamic> sitter) async {
    if (pets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('You have no pets. Add a pet before hiring a sitter.')),
      );
      return;
    }

    String? selectedPetId = pets.isNotEmpty ? pets.first['id'] as String? : null;
    DateTime selectedStart = DateTime.now();
    DateTime? selectedEnd;

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
              child: Wrap(
                children: [
                  Center(
                    child: Container(
                      height: 6,
                      width: 60,
                      margin: EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(4)),
                    ),
                  ),
                  Text('Hire ${sitter['name'] ?? 'Sitter'}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: deepRed)),
                  SizedBox(height: 12),

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
                  SizedBox(height: 12),

                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: selectedStart,
                              firstDate: DateTime.now().subtract(Duration(days: 365)),
                              lastDate: DateTime.now().add(Duration(days: 365 * 2)),
                            );
                            if (picked != null) setModalState(() => selectedStart = picked);
                          },
                          child: Text('Start: ${selectedStart.toLocal().toString().split(' ')[0]}'),
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: selectedEnd ?? selectedStart,
                              firstDate: selectedStart,
                              lastDate: DateTime.now().add(Duration(days: 365 * 2)),
                            );
                            if (picked != null) setModalState(() => selectedEnd = picked);
                          },
                          child: Text('End: ${selectedEnd != null ? selectedEnd!.toLocal().toString().split(' ')[0] : 'Not set'}'),
                        ),
                      ),
                    ],
                  ),

                  SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () async {
                        if (selectedPetId == null) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Please select a pet.')));
                          return;
                        }
                        Navigator.of(context).pop();
                        await _createSittingJob(sitter['id'] as String, selectedPetId!, selectedStart, selectedEnd);
                      },
                      child: Text('Confirm Hire'),
                      style: ElevatedButton.styleFrom(backgroundColor: deepRed),
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

  Future<void> _createSittingJob(String sitterId, String petId, DateTime start, DateTime? end) async {
    try {
      final payload = {
        'sitter_id': sitterId,
        'pet_id': petId,
        'start_date': start.toIso8601String().substring(0, 10),
        'end_date': end != null ? end.toIso8601String().substring(0, 10) : null,
        'status': 'Pending',
      };

      await supabase.from('sitting_jobs').insert(payload);

      // Optimistically update UI so the Hire button immediately shows "Pending"
      setState(() {
        pendingSitterIds.add(sitterId);
      });

      // Give user feedback
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sitter hired — request sent.')));
      // Refresh pending requests so UI stays in sync with backend
      await fetchOwnerPendingRequests();
    } catch (e) {
      print('❌ createSittingJob ERROR: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to create sitting job.')));
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

  Widget _buildOwnerHome() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Text(
            'Find Pet Sitters',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: deepRed),
          ),
        ),
        SizedBox(height: 16),
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
                height: 600, // Adjust height if needed
                child: TabBarView(
                  controller: _sitterTabController,
                  children: [
                    _buildSitterList(availableSitters),
                    _buildSitterList(availableSitters.where((s) => s['is_available'] == true).toList()),
                    _buildSitterList(availableSitters.where((s) => (s['rating'] ?? 0) >= 4.5).toList()),
                  ],
                ),
              )
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Hi, $userName!',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: deepRed),
        ),
        SizedBox(height: 8),
        Text("Here’s your sitter dashboard today:", style: TextStyle(color: deepRed)),
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
                            color: status == 'Accepted'
                                ? Colors.green.withOpacity(0.15)
                                : status == 'Declined'
                                    ? Colors.red.withOpacity(0.15)
                                    : Colors.orange.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            status,
                            style: TextStyle(
                              color: status == 'Accepted'
                                  ? Colors.green[800]
                                  : status == 'Declined'
                                      ? Colors.red[800]
                                      : Colors.orange[800],
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: status == 'Pending'
                                  ? () => _updateJobStatus(jobId, 'Accepted')
                                  : null,
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
                              onPressed: status == 'Pending'
                                  ? () => _updateJobStatus(jobId, 'Declined')
                                  : null,
                              icon: Icon(Icons.close, color: deepRed),
                              label: Text('Decline', style: TextStyle(color: deepRed)),
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(color: deepRed),
                              ),
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
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),

        SizedBox(height: 24),

        // ⭐ Reviews
        _sectionWithBorder(
          title: "Reviews",
          child: SizedBox(
            height: 140,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _buildReviewCard("Very caring and always on time!", "Maria D."),
                _buildReviewCard("Loves animals like family!", "John P."),
                _buildReviewCard("Always punctual and friendly!", "Lisa M."),
              ],
            ),
          ),
        ),

        SizedBox(height: 24),

        // 🗓️ Today’s Schedule
        _sectionWithBorder(
          title: "Today’s Schedule",
          child: Column(
            children: [
              _buildScheduleItem("9:00 AM", "Luna", "Feed and walk"),
              _buildScheduleItem("2:00 PM", "Max", "Play session"),
            ],
          ),
        ),

        SizedBox(height: 24),

        // 🧾 Completed Jobs
        _sectionWithBorder(
          title: "Completed Jobs",
          child: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green),
              SizedBox(width: 12),
              Text("You’ve completed 12 jobs", style: TextStyle(fontSize: 16, color: deepRed)),
            ],
          ),
        ),
      ],
    );
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

  Widget _buildReviewCard(String review, String owner) {
    return Container(
      width: 250,
      margin: EdgeInsets.only(right: 12),
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
          Row(children: List.generate(5, (index) => Icon(Icons.star, size: 18, color: Colors.orange))),
          SizedBox(height: 8),
          Text('"$review"', style: TextStyle(fontStyle: FontStyle.italic)),
          Spacer(),
          Text('– $owner', style: TextStyle(color: Colors.grey[600])),
        ],
      ),
    );
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
}
