import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geocoding/geocoding.dart';

class LocationPicker extends StatefulWidget {
  @override
  _LocationPickerState createState() => _LocationPickerState();
}

class _LocationPickerState extends State<LocationPicker> {
  final MapController mapController = MapController();
  LatLng? selectedLocation;
  String address = '';

  // Define Agusan del Norte bounds manually
  final LatLngBounds agusanBounds = LatLngBounds(
    LatLng(8.95, 125.35), // SW
    LatLng(9.25, 125.85), // NE
  );

  void _onTapMap(LatLng latLng) async {
    if (!agusanBounds.contains(latLng)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Please select within Agusan del Norte")),
      );
      return;
    }

    setState(() => selectedLocation = latLng);

    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(
        latLng.latitude,
        latLng.longitude,
      );

      if (placemarks.isNotEmpty) {
        final place = placemarks.first;
        setState(() {
          address =
              '${place.street}, ${place.locality}, ${place.administrativeArea}, ${place.country}';
        });
      }
    } catch (e) {
      print("Geocoding error: $e");
    }
  }

  void _confirmSelection() {
    if (selectedLocation != null) {
      Navigator.pop(context, {
        'latitude': selectedLocation!.latitude,
        'longitude': selectedLocation!.longitude,
        'address': address,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Select Location')),
      body: FlutterMap(
        mapController: mapController,
        options: MapOptions(
          center: LatLng(9.0393, 125.5746),
          zoom: 11.5,
          maxZoom: 19.0, 
          minZoom: 10.5,
          onTap: (tapPosition, latLng) => _onTapMap(latLng),
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
            subdomains: ['a', 'b', 'c', 'd'],
            userAgentPackageName: 'com.example.pettrackcare',
            retinaMode: true,
          ),
          if (selectedLocation != null)
            MarkerLayer(
              markers: [
                Marker(
                  point: selectedLocation!,
                  width: 40,
                  height: 40,
                  child: Icon(Icons.location_pin, color: Colors.red, size: 40),
                ),
              ],
            ),
        ],
      ),
      bottomNavigationBar: selectedLocation != null
          ? Padding(
              padding: const EdgeInsets.all(12),
              child: ElevatedButton.icon(
                icon: Icon(Icons.check),
                label: Text('Confirm Location'),
                onPressed: _confirmSelection,
              ),
            )
          : null,
    );
  }
}
