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

  // Caraga Region (Region XIII) bounding box
  final LatLngBounds caragaBounds = LatLngBounds(
    LatLng(8.0, 125.0), // SW
    LatLng(10.6, 126.6), // NE
  );

  void _onTapMap(LatLng latLng) async {
    // Validate inside Caraga Region
    if (!caragaBounds.contains(latLng)) {
      // Guard against deactivated context
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text("Please select within the Caraga Region")),
      );
      return;
    }

    if (!mounted) return;
    setState(() => selectedLocation = latLng);

    try {
      final placemarks = await placemarkFromCoordinates(
        latLng.latitude,
        latLng.longitude,
      );

      if (!mounted) return;

      if (placemarks.isNotEmpty) {
        final place = placemarks.first;
        setState(() {
          address =
              '${place.street}, ${place.locality}, ${place.administrativeArea}, ${place.country}';
        });

        // Optional feedback
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text("Location selected: $address")),
        );
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
    } else {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text("Please select a location first")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Select Location')),
      body: FlutterMap(
        mapController: mapController,
        options: MapOptions(
          initialCenter: LatLng(8.95, 125.54), // Butuan City
          initialZoom: 9.0,
          maxZoom: 19.0,
          minZoom: 7.5,
          onTap: (tapPosition, latLng) => _onTapMap(latLng),
          // Lock camera inside Caraga Region
          cameraConstraint: CameraConstraint.contain(bounds: caragaBounds),
        ),
        children: [
          TileLayer(
            urlTemplate:
                'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
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
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(12),
        child: ElevatedButton.icon(
          icon: Icon(Icons.check),
          label: Text('Confirm Location'),
          onPressed: _confirmSelection,
        ),
      ),
    );
  }
}
