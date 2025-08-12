import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:intl/intl.dart';

const deepRed = Color(0xFFB82132);
const coral = Color(0xFFD2665A);
const peach = Color(0xFFF2B28C);
const lightBlush = Color(0xFFF6DED8);

class CalendarScreen extends StatefulWidget {
  final dynamic sitter;

  const CalendarScreen({Key? key, required this.sitter}) : super(key: key);

  @override
  _CalendarScreenState createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  final supabase = Supabase.instance.client;
  Map<DateTime, List<String>> _bookedSlots = {};
  List<String> _timeSlots = [];

  @override
  void initState() {
    super.initState();
    _fetchBookedSlots();
  }

  Future<void> _fetchBookedSlots() async {
    final sitterId = Supabase.instance.client.auth.currentUser?.id;
    if (sitterId == null) return;
    final response = await supabase
        .from('sitter_slots')
        .select()
        .eq('sitter_id', sitterId);

    final data = response as List<dynamic>;

    setState(() {
      _bookedSlots.clear();
      for (var item in data) {
        DateTime date = DateTime.parse(item['date']);
        String slot = item['time_slot'];
        if (_bookedSlots.containsKey(date)) {
          _bookedSlots[date]!.add(slot);
        } else {
          _bookedSlots[date] = [slot];
        }
      }
    });
  }

  void _onDaySelected(DateTime selectedDay, DateTime focusedDay) async {
    setState(() {
      _selectedDay = selectedDay;
      _focusedDay = focusedDay;
    });

    final sitterId = Supabase.instance.client.auth.currentUser?.id;
    if (sitterId == null) return;

    final response = await supabase
        .from('sitter_slots')
        .select()
        .eq('sitter_id', sitterId)
        .eq('date', DateFormat('yyyy-MM-dd').format(selectedDay));

    final data = response as List<dynamic>;
    setState(() {
      _timeSlots = data
          .map((slot) =>
              '${slot['time_slot']} - ${slot['is_booked'] ? "Booked" : "Available"}')
          .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sitter Calendar'),
        backgroundColor: deepRed,
      ),
      body: Column(
        children: [
          TableCalendar(
            focusedDay: _focusedDay,
            firstDay: DateTime(DateTime.now().year - 1, 1, 1),
            lastDay: DateTime(DateTime.now().year + 2, 12, 31),
            selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
            onDaySelected: _onDaySelected,
            calendarStyle: CalendarStyle(
              todayDecoration: BoxDecoration(
                color: peach,
                shape: BoxShape.circle,
              ),
              selectedDecoration: BoxDecoration(
                color: coral,
                shape: BoxShape.circle,
              ),
              markerDecoration: BoxDecoration(
                color: deepRed,
                shape: BoxShape.circle,
              ),
            ),
            calendarBuilders: CalendarBuilders(
              markerBuilder: (context, date, events) {
                if (_bookedSlots.containsKey(date)) {
                  return Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: deepRed,
                        shape: BoxShape.circle,
                      ),
                    ),
                  );
                }
                return null;
              },
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _selectedDay != null
                ? 'Available Slots on ${DateFormat.yMMMd().format(_selectedDay!)}'
                : 'Select a date to view available slots',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              color: lightBlush.withOpacity(0.2),
              child: _timeSlots.isEmpty
                  ? const Center(child: Text("No slots found."))
                  : ListView.builder(
                      itemCount: _timeSlots.length,
                      itemBuilder: (context, index) {
                        return ListTile(
                          title: Text(
                            _timeSlots[index],
                            style: const TextStyle(color: deepRed),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
