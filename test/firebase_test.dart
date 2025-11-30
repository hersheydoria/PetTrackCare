import 'dart:convert';
import 'dart:io';

/// Simple Firebase connectivity test
void main() async {
  const String firebaseHost = 'pettrackcare-default-rtdb.firebaseio.com';
  const String authKey = 'ZkOYbj9lrqchs1DR5PaAJPoEljYkqFBXZqEF1FaY';
  
  try {
    // Test Firebase connection
    final url = 'https://$firebaseHost/.json?auth=$authKey';
    print('🔍 Testing Firebase connection: $url');
    
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    
    if (response.statusCode == 200) {
      final responseBody = await response.transform(utf8.decoder).join();
      final data = jsonDecode(responseBody);
      
      print('✅ Firebase connection successful!');
      print('📊 Response data type: ${data.runtimeType}');
      
      if (data is Map) {
        print('📋 Keys in Firebase root: ${data.keys.toList()}');
        
        // Check for locations data
        if (data.containsKey('locations')) {
          final locations = data['locations'];
          print('📍 Locations found: ${locations.runtimeType}');
          
          if (locations is Map) {
            print('📍 Location entries count: ${locations.keys.length}');
            print('📍 First few entries: ${locations.keys.take(3).toList()}');
            
            // Sample the first entry
            if (locations.isNotEmpty) {
              final firstKey = locations.keys.first;
              final firstEntry = locations[firstKey];
              print('📍 Sample entry ($firstKey): $firstEntry');
              print('📍 Sample entry type: ${firstEntry.runtimeType}');
              
              if (firstEntry is Map) {
                print('📍 Entry fields: ${firstEntry.keys.toList()}');
                print('   - lat: ${firstEntry['lat']} (${firstEntry['lat'].runtimeType})');
                print('   - long: ${firstEntry['long']} (${firstEntry['long'].runtimeType})');
                print('   - device_mac: ${firstEntry['device_mac']} (${firstEntry['device_mac'].runtimeType})');
              }
            }
          }
        } else {
          print('❌ No "locations" key found in Firebase root');
          print('Available keys: ${data.keys.toList()}');
          
          // Check if data is stored at root level
          bool foundLocationData = false;
          for (final entry in data.entries) {
            if (entry.value is Map) {
              final entryData = entry.value as Map;
              if (entryData.containsKey('lat') && entryData.containsKey('long') && entryData.containsKey('device_mac')) {
                print('🎯 Found location data at root level in key: ${entry.key}');
                print('   Data: ${entry.value}');
                foundLocationData = true;
                break;
              }
            }
          }
          
          if (!foundLocationData) {
            print('⚠️  No location data found in expected format');
            // Show first few entries for debugging
            print('Sample entries:');
            data.entries.take(3).forEach((entry) {
              print('  ${entry.key}: ${entry.value}');
            });
          }
        }
      } else {
        print('📊 Data is not a Map: $data');
      }
      
    } else {
      print('❌ Firebase connection failed: ${response.statusCode}');
      final responseBody = await response.transform(utf8.decoder).join();
      print('Response body: $responseBody');
    }
    
    client.close();
    
  } catch (e) {
    print('❌ Error testing Firebase: $e');
  }
}