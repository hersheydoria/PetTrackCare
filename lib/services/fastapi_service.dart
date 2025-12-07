import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FastApiService {
  FastApiService._internal();

  static final FastApiService instance = FastApiService._internal();
  static const _tokenKey = 'fastapi_access_token';

  final http.Client _client = http.Client();
  String? _accessToken;

  String get _baseUrl {
    final envUrl = dotenv.env['FASTAPI_BASE_URL']?.trim();
    if (envUrl == null || envUrl.isEmpty) {
      return 'http://192.168.100.23:8000';
    }
    return envUrl.replaceAll(RegExp(r'/+$'), '');
  }

  bool get hasToken => _accessToken != null && _accessToken!.isNotEmpty;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString(_tokenKey);
  }

  Future<Map<String, String>> get _jsonHeaders async {
    await _ensureAccessTokenLoaded();
    final headers = {'Content-Type': 'application/json'};
    if (_accessToken != null && _accessToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $_accessToken';
    }
    return headers;
  }

  Map<String, String> get _formHeaders => {
    'Content-Type': 'application/x-www-form-urlencoded',
  };

  Future<void> _ensureAccessTokenLoaded() async {
    if (_accessToken != null && _accessToken!.isNotEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_tokenKey);
    if (saved != null && saved.isNotEmpty) {
      _accessToken = saved;
    }
  }

  Future<void> login(String email, String password) async {
    final url = Uri.parse('$_baseUrl/auth/login');
    final response = await _client.post(
      url,
      headers: _formHeaders,
      body: {'username': email, 'password': password},
    );

    if (response.statusCode != 200) {
      throw Exception('FastAPI login failed (${response.statusCode})');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final token = data['access_token'] as String?;
    if (token == null || token.isEmpty) {
      throw Exception('FastAPI login response missing access token');
    }

    await _persistToken(token);
  }

  Future<void> logout() async {
    _accessToken = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }

  Future<void> signUp({
    required String email,
    required String password,
    String? name,
    String role = 'Pet Owner',
    String? address,
    String? profilePicture,
    String? status,
  }) async {
    final url = Uri.parse('$_baseUrl/auth/signup');
    final payload = {
      'email': email,
      'password': password,
      'role': role,
      if (name != null) 'name': name,
      if (address != null) 'address': address,
      if (profilePicture != null) 'profile_picture': profilePicture,
      if (status != null) 'status': status,
    };

    final response = await _client.post(
      url,
      headers: await _jsonHeaders,
      body: jsonEncode(payload),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('FastAPI signup failed (${response.statusCode})');
    }
  }

  Future<List<Map<String, dynamic>>> fetchPets({
    String? ownerId,
    List<String>? petIds,
  }) async {
    final queryParams = <String, String>{};
    if (ownerId != null && ownerId.isNotEmpty) {
      queryParams['owner_id'] = ownerId;
    }
    if (petIds != null && petIds.isNotEmpty) {
      queryParams['pet_ids'] = petIds.join(',');
    }
    final uri = Uri.parse(
      '$_baseUrl/pets/',
    ).replace(queryParameters: queryParams.isEmpty ? null : queryParams);
    final response = await _client.get(uri, headers: await _jsonHeaders);

    if (response.statusCode != 200) {
      throw Exception('FastAPI fetch pets failed (${response.statusCode})');
    }

    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> createPet(Map<String, dynamic> payload) async {
    final uri = Uri.parse('$_baseUrl/pets/');
    final response = await _client.post(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI create pet failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<void> updatePet(String petId, Map<String, dynamic> payload) async {
    final uri = Uri.parse('$_baseUrl/pets/$petId');
    final response = await _client.patch(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI update pet failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<void> deletePet(String petId) async {
    final uri = Uri.parse('$_baseUrl/pets/$petId');
    final response = await _client.delete(uri, headers: await _jsonHeaders);
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI delete pet failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<List<Map<String, dynamic>>> fetchBehaviorLogs({
    String? petId,
    String? userId,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 100,
  }) async {
    final queryParams = <String, String>{
      'limit': limit.toString(),
      if (petId != null && petId.isNotEmpty) 'pet_id': petId,
      if (userId != null && userId.isNotEmpty) 'user_id': userId,
      if (startDate != null) 'start_date': _dateOnly(startDate),
      if (endDate != null) 'end_date': _dateOnly(endDate),
    };
    final uri = Uri.parse('$_baseUrl/behavior_logs/').replace(
      queryParameters: queryParams.isEmpty ? null : queryParams,
    );
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception('FastAPI fetch behavior logs failed (${response.statusCode})');
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> deleteBehaviorLog(String logId) async {
    final uri = Uri.parse('$_baseUrl/behavior_logs/$logId');
    final response = await _client.delete(uri, headers: await _jsonHeaders);
    if (response.statusCode >= 400) {
      throw Exception('FastAPI delete behavior log failed (${response.statusCode}): ${response.body}');
    }
  }

  Future<Map<String, dynamic>> createBehaviorLog(Map<String, dynamic> payload) async {
    final uri = Uri.parse('$_baseUrl/behavior_logs/');
    final response = await _client.post(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      throw Exception('FastAPI create behavior log failed (${response.statusCode}): ${response.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<Map<String, dynamic>> updateBehaviorLog(String logId, Map<String, dynamic> payload) async {
    final uri = Uri.parse('$_baseUrl/behavior_logs/$logId');
    final response = await _client.patch(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      throw Exception('FastAPI update behavior log failed (${response.statusCode}): ${response.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<List<Map<String, dynamic>>> fetchLocationHistory(
    String petId, {
    int limit = 8,
  }) async {
    final uri = Uri.parse('$_baseUrl/location/pet/$petId').replace(
      queryParameters: {'limit': limit.toString()},
    );
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception('FastAPI fetch location history failed (${response.statusCode})');
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> createLocation(Map<String, dynamic> payload) async {
    final uri = Uri.parse('$_baseUrl/location/');
    final response = await _client.post(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      throw Exception('FastAPI create location failed (${response.statusCode}): ${response.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<Map<String, dynamic>> fetchLatestLocationForPet(String petId) async {
    final uri = Uri.parse('$_baseUrl/location/pet/$petId/latest');
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception('FastAPI fetch latest location failed (${response.statusCode})');
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<Map<String, dynamic>?> fetchLocationByFirebaseEntry(String entryId) async {
    final uri = Uri.parse('$_baseUrl/location/firebase/$entryId');
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode != 200) {
      throw Exception('FastAPI fetch location by Firebase entry failed (${response.statusCode})');
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<Map<String, dynamic>?> fetchDeviceForPet(String petId) async {
    final uri = Uri.parse('$_baseUrl/device-map/pet/$petId');
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode != 200) {
      throw Exception('FastAPI fetch device map failed (${response.statusCode})');
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<Map<String, dynamic>?> fetchDeviceForDevice(String deviceId) async {
    final uri = Uri.parse('$_baseUrl/device-map/device/$deviceId');
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode != 200) {
      throw Exception('FastAPI fetch device map by device failed (${response.statusCode})');
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<Map<String, dynamic>> assignDeviceToPet({
    required String petId,
    required String deviceId,
  }) async {
    final uri = Uri.parse('$_baseUrl/device-map/');
    final response = await _client.post(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode({
        'pet_id': petId,
        'device_id': deviceId,
      }),
    );
    if (response.statusCode >= 400) {
      throw Exception('FastAPI assign device failed (${response.statusCode}): ${response.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<void> removeDeviceFromPet(String petId) async {
    final uri = Uri.parse('$_baseUrl/device-map/pet/$petId');
    final response = await _client.delete(uri, headers: await _jsonHeaders);
    if (response.statusCode >= 400) {
      throw Exception('FastAPI remove device failed (${response.statusCode}): ${response.body}');
    }
  }

  Future<List<Map<String, dynamic>>> fetchConversations({
    int limit = 24,
  }) async {
    final uri = Uri.parse(
      '$_baseUrl/messages/conversations',
    ).replace(queryParameters: {'limit': limit.toString()});
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception(
        'FastAPI fetch conversations failed (${response.statusCode})',
      );
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> fetchConversationThread(
    String peerId, {
    int limit = 150,
  }) async {
    final uri = Uri.parse(
      '$_baseUrl/messages/thread/$peerId',
    ).replace(queryParameters: {'limit': limit.toString()});
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception(
        'FastAPI fetch conversation thread failed (${response.statusCode})',
      );
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> sendMessage(Map<String, dynamic> payload) async {
    final uri = Uri.parse('$_baseUrl/messages/');
    final response = await _client.post(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI send message failed (${response.statusCode}): ${response.body}',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<void> markMessagesAsSeen(String peerId) async {
    final uri = Uri.parse(
      '$_baseUrl/messages/seen',
    ).replace(queryParameters: {'peer_id': peerId});
    final response = await _client.post(uri, headers: await _jsonHeaders);
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI mark messages seen failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<List<Map<String, dynamic>>> pollConversationUpdates(
    String peerId, {
    DateTime? since,
    int limit = 150,
  }) async {
    final thread = await fetchConversationThread(peerId, limit: limit);
    if (since == null) {
      return thread;
    }
    return thread.where((message) {
      final sentAt = message['sent_at']?.toString();
      if (sentAt == null || sentAt.isEmpty) return true;
      final parsed = DateTime.tryParse(sentAt);
      return parsed != null && parsed.isAfter(since);
    }).toList();
  }

  Future<Map<String, dynamic>?> fetchLatestMessage(String peerId) async {
    final uri = Uri.parse('$_baseUrl/messages/latest/$peerId');
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode != 200) {
      throw Exception('FastAPI fetch latest message failed (${response.statusCode}): ${response.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<Map<String, dynamic>> sendCallSignal({
    required String recipientId,
    required String senderId,
    required String type,
    required String message,
    String? callId,
    String? callMode,
    Map<String, dynamic>? metadata,
  }) async {
    final payload = <String, dynamic>{
      'sender_id': senderId,
      'receiver_id': recipientId,
      'content': message,
      'type': type,
      'is_seen': false,
      if (callId != null) 'call_id': callId,
      if (callMode != null) 'call_mode': callMode,
      if (metadata != null && metadata.isNotEmpty) 'metadata': metadata,
    };
    return sendMessage(payload);
  }

  Future<void> updateTypingStatus(String chatWithId, bool isTyping) async {
    final uri = Uri.parse('$_baseUrl/messages/typing-status');
    final response = await _client.post(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode({'chat_with_id': chatWithId, 'is_typing': isTyping}),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI update typing status failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<bool> fetchTypingStatus(String peerId) async {
    final uri = Uri.parse('$_baseUrl/messages/typing-status/$peerId');
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception(
        'FastAPI fetch typing status failed (${response.statusCode})',
      );
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['is_typing'] as bool? ?? false;
  }

  Future<Map<String, dynamic>> _uploadMedia({
    required File file,
    String type = 'images',
    String? contentType,
  }) async {
    final uri = Uri.parse('$_baseUrl/media/upload');
    await _ensureAccessTokenLoaded();
    final request = http.MultipartRequest('POST', uri);
    if (_accessToken != null && _accessToken!.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $_accessToken';
    }
    request.fields['type'] = type;
    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        file.path,
        contentType: contentType != null ? MediaType.parse(contentType) : null,
      ),
    );
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI upload media failed (${response.statusCode}): ${response.body}',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<Map<String, dynamic>> uploadChatMedia({
    required File file,
    required String type,
    String? contentType,
  }) async {
    return _uploadMedia(file: file, type: type, contentType: contentType);
  }

  Future<Map<String, dynamic>> uploadCommunityMedia({
    required File file,
    String type = 'community',
    String? contentType,
  }) async {
    return _uploadMedia(
      file: file,
      type: type,
      contentType: contentType ?? 'image/jpeg',
    );
  }

  Future<String> uploadProfileImage(
    File file, {
    String type = 'images',
    String? contentType,
  }) async {
    final uploaded = await _uploadMedia(
      file: file,
      type: type,
      contentType: contentType ?? 'image/jpeg',
    );
    final url = uploaded['url'];
    if (url is! String || url.isEmpty) {
      throw Exception('FastAPI upload profile image failed: missing URL');
    }
    return url;
  }

  String resolveMediaUrl(String path) {
    if (path.isEmpty) return '';
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    var normalized = path.startsWith('/') ? path : '/$path';
    if (!normalized.startsWith('/media/')) {
      normalized = '/media$normalized';
    }
    return '$_baseUrl$normalized';
  }

  Future<List<Map<String, dynamic>>> fetchPosts({
    int limit = 20,
    int offset = 0,
  }) async {
    final uri = Uri.parse('$_baseUrl/posts/').replace(
      queryParameters: {'limit': limit.toString(), 'offset': offset.toString()},
    );
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception('FastAPI fetch posts failed (${response.statusCode})');
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> fetchCommunityPosts({
    int limit = 20,
    int offset = 0,
    String? postType,
    String? userId,
  }) async {
    final queryParams = <String, String>{
      'limit': limit.toString(),
      'offset': offset.toString(),
      if (postType != null) 'type': postType,
      if (userId != null) 'user_id': userId,
    };
    final uri = Uri.parse(
      '$_baseUrl/community/posts',
    ).replace(queryParameters: queryParams);
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception(
        'FastAPI fetch community posts failed (${response.statusCode})',
      );
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> fetchCommunityPost(String postId) async {
    final uri = Uri.parse('$_baseUrl/community/posts/$postId');
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception(
        'FastAPI fetch community post failed (${response.statusCode})',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<Map<String, dynamic>> createCommunityPost(
    Map<String, dynamic> payload,
  ) async {
    final uri = Uri.parse('$_baseUrl/community/posts');
    final response = await _client.post(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI create community post failed (${response.statusCode}): ${response.body}',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<Map<String, dynamic>> updateCommunityPost(
    String postId,
    Map<String, dynamic> payload,
  ) async {
    final uri = Uri.parse('$_baseUrl/community/posts/$postId');
    final response = await _client.patch(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI update community post failed (${response.statusCode}): ${response.body}',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<void> deleteCommunityPost(String postId) async {
    final uri = Uri.parse('$_baseUrl/community/posts/$postId');
    final response = await _client.delete(uri, headers: await _jsonHeaders);
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI delete community post failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<Map<String, dynamic>> createCommunityComment({
    required String postId,
    required String content,
  }) async {
    final uri = Uri.parse('$_baseUrl/community/posts/$postId/comments');
    final response = await _client.post(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode({'content': content}),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI create community comment failed (${response.statusCode}): ${response.body}',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<Map<String, dynamic>> updateCommunityComment({
    required String commentId,
    required String content,
  }) async {
    final uri = Uri.parse('$_baseUrl/community/comments/$commentId');
    final response = await _client.patch(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode({'content': content}),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI update community comment failed (${response.statusCode}): ${response.body}',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<void> deleteCommunityComment({required String commentId}) async {
    final uri = Uri.parse('$_baseUrl/community/comments/$commentId');
    final response = await _client.delete(uri, headers: await _jsonHeaders);
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI delete community comment failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<Map<String, dynamic>> createCommunityReply({
    required String commentId,
    required String content,
  }) async {
    final uri = Uri.parse('$_baseUrl/community/comments/$commentId/replies');
    final response = await _client.post(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode({'content': content}),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI create community reply failed (${response.statusCode}): ${response.body}',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<Map<String, dynamic>> updateCommunityReply({
    required String commentId,
    required String replyId,
    required String content,
  }) async {
    final uri = Uri.parse(
      '$_baseUrl/community/comments/$commentId/replies/$replyId',
    );
    final response = await _client.patch(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode({'content': content}),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI update reply failed (${response.statusCode}): ${response.body}',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<void> deleteCommunityReply({
    required String commentId,
    required String replyId,
  }) async {
    final uri = Uri.parse(
      '$_baseUrl/community/comments/$commentId/replies/$replyId',
    );
    final response = await _client.delete(uri, headers: await _jsonHeaders);
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI delete reply failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<List<Map<String, dynamic>>> fetchRepliesForComment({
    required String commentId,
    int limit = 5,
    int offset = 0,
  }) async {
    final uri = Uri.parse(
      '$_baseUrl/community/comments/$commentId/replies',
    ).replace(
      queryParameters: {'limit': limit.toString(), 'offset': offset.toString()},
    );
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception(
        'FastAPI fetch comment replies failed (${response.statusCode})',
      );
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> likeCommunityPost(String postId) async {
    final uri = Uri.parse('$_baseUrl/community/posts/$postId/likes');
    final response = await _client.post(uri, headers: await _jsonHeaders);
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI like post failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<void> unlikeCommunityPost(String postId) async {
    final uri = Uri.parse('$_baseUrl/community/posts/$postId/likes');
    final response = await _client.delete(uri, headers: await _jsonHeaders);
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI unlike post failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<void> likeCommunityComment(String commentId) async {
    final uri = Uri.parse('$_baseUrl/community/comments/$commentId/likes');
    final response = await _client.post(uri, headers: await _jsonHeaders);
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI like comment failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<void> unlikeCommunityComment(String commentId) async {
    final uri = Uri.parse('$_baseUrl/community/comments/$commentId/likes');
    final response = await _client.delete(uri, headers: await _jsonHeaders);
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI unlike comment failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<List<Map<String, dynamic>>> fetchBookmarkedPosts() async {
    final uri = Uri.parse('$_baseUrl/community/bookmarks/me');
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception(
        'FastAPI fetch bookmarks failed (${response.statusCode})',
      );
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map<Map<String, dynamic>?>((entry) {
          final bookmark = Map<String, dynamic>.from(entry as Map);
          final post = bookmark['post'] as Map<String, dynamic>?;
          if (post == null) return null;
          final user = post['user'] as Map<String, dynamic>?;
          return {
            'id': post['id'],
            'content': post['content'],
            'image_url': post['image_url'],
            'created_at': bookmark['created_at'] ?? post['created_at'],
            'user': user,
          };
        })
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  Future<void> bookmarkCommunityPost(String postId) async {
    final uri = Uri.parse('$_baseUrl/community/posts/$postId/bookmarks');
    final response = await _client.post(uri, headers: await _jsonHeaders);
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI bookmark post failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<void> unbookmarkCommunityPost(String postId) async {
    final uri = Uri.parse('$_baseUrl/community/posts/$postId/bookmarks');
    final response = await _client.delete(uri, headers: await _jsonHeaders);
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI remove bookmark failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<void> reportCommunityPost({
    required String postId,
    required String reason,
  }) async {
    final uri = Uri.parse('$_baseUrl/community/posts/$postId/reports');
    final response = await _client.post(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode({'reason': reason}),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI report post failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<List<Map<String, dynamic>>> searchUsers(String query) async {
    final uri = Uri.parse(
      '$_baseUrl/users',
    ).replace(queryParameters: {'query': query, 'limit': '5'});
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception('FastAPI search users failed (${response.statusCode})');
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> createNotification(
    Map<String, dynamic> payload,
  ) async {
    final uri = Uri.parse('$_baseUrl/notifications/');
    final response = await _client.post(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI create notification failed (${response.statusCode}): ${response.body}',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<void> submitFeedback(String message) async {
    final uri = Uri.parse('$_baseUrl/feedback/');
    final response = await _client.post(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode({'message': message}),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI submit feedback failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<List<Map<String, dynamic>>> fetchNotifications() async {
    final uri = Uri.parse('$_baseUrl/notifications/me');
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception(
        'FastAPI fetch notifications failed (${response.statusCode})',
      );
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> updateNotification(
    String notificationId,
    Map<String, dynamic> payload,
  ) async {
    final uri = Uri.parse('$_baseUrl/notifications/$notificationId');
    final response = await _client.patch(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI update notification failed (${response.statusCode}): ${response.body}',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<void> createPost(Map<String, dynamic> payload) async {
    final uri = Uri.parse('$_baseUrl/posts/');
    final response = await _client.post(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI create post failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<Map<String, dynamic>> fetchUserById(String userId) async {
    final uri = Uri.parse('$_baseUrl/users/$userId');
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception('FastAPI fetch user failed (${response.statusCode})');
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<List<Map<String, dynamic>>> fetchUsers({
    int limit = 20,
    int offset = 0,
    String? query,
  }) async {
    final queryParams = <String, String>{
      'limit': limit.toString(),
      'offset': offset.toString(),
      if (query != null && query.isNotEmpty) 'query': query,
    };
    final uri = Uri.parse('$_baseUrl/users/').replace(
      queryParameters: queryParams.isEmpty ? null : queryParams,
    );
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception('FastAPI fetch users failed (${response.statusCode})');
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<String>> fetchAllUserIds({int pageSize = 200}) async {
    final ids = <String>[];
    int offset = 0;
    while (true) {
      final batch = await fetchUsers(limit: pageSize, offset: offset);
      if (batch.isEmpty) {
        break;
      }
      ids.addAll(batch
          .map((user) => user['id']?.toString())
          .where((id) => id != null)
          .cast<String>());
      if (batch.length < pageSize) break;
      offset += batch.length;
    }
    return ids;
  }

  Future<Map<String, dynamic>> fetchCurrentUser() async {
    final uri = Uri.parse('$_baseUrl/users/me');
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception(
        'FastAPI fetch current user failed (${response.statusCode})',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<Map<String, dynamic>> updateCurrentUser(
    Map<String, dynamic> payload,
  ) async {
    final uri = Uri.parse('$_baseUrl/users/me');
    final response = await _client.patch(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI update current user failed (${response.statusCode}): ${response.body}',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<void> deleteCurrentUser() async {
    final uri = Uri.parse('$_baseUrl/users/me');
    final response = await _client.delete(uri, headers: await _jsonHeaders);
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI delete current user failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<List<Map<String, dynamic>>> fetchSitters({
    String? locationQuery,
    int limit = 20,
    int offset = 0,
  }) async {
    final queryParams = <String, String>{
      'limit': limit.toString(),
      'offset': offset.toString(),
    };
    if (locationQuery != null && locationQuery.isNotEmpty) {
      queryParams['location'] = locationQuery;
    }
    final uri = Uri.parse(
      '$_baseUrl/sitters/',
    ).replace(queryParameters: queryParams);
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception('FastAPI fetch sitters failed (${response.statusCode})');
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> fetchSitterProfile(String userId) async {
    final uri = Uri.parse('$_baseUrl/sitters/$userId');
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception(
        'FastAPI fetch sitter profile failed (${response.statusCode})',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<void> updateSitterProfile(
    String userId,
    Map<String, dynamic> payload,
  ) async {
    final uri = Uri.parse('$_baseUrl/sitters/$userId');
    final response = await _client.patch(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI update sitter profile failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<List<Map<String, dynamic>>> fetchSitterReviews(String userId) async {
    final uri = Uri.parse('$_baseUrl/sitters/$userId/reviews');
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception(
        'FastAPI fetch sitter reviews failed (${response.statusCode})',
      );
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> fetchSittingJobsForSitter(
    String userId,
  ) async {
    final uri = Uri.parse('$_baseUrl/sitting_jobs/sitter/$userId');
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception(
        'FastAPI fetch sitter jobs failed (${response.statusCode})',
      );
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> fetchOwnerJobs({
    required String ownerId,
    String? status,
  }) async {
    final queryParams = <String, String>{if (status != null) 'status': status};
    final uri = Uri.parse(
      '$_baseUrl/sitting_jobs/owner/$ownerId',
    ).replace(queryParameters: queryParams.isEmpty ? null : queryParams);
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception(
        'FastAPI fetch owner jobs failed (${response.statusCode})',
      );
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> createSittingJob(
    Map<String, dynamic> payload,
  ) async {
    final uri = Uri.parse('$_baseUrl/sitting_jobs/');
    final response = await _client.post(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI create job failed (${response.statusCode}): ${response.body}',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<Map<String, dynamic>> updateSittingJob(
    String jobId,
    Map<String, dynamic> payload,
  ) async {
    final uri = Uri.parse('$_baseUrl/sitting_jobs/$jobId');
    final response = await _client.patch(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI update job failed (${response.statusCode}): ${response.body}',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<void> createSitterReview(
    String userId,
    Map<String, dynamic> payload,
  ) async {
    final uri = Uri.parse('$_baseUrl/sitters/$userId/reviews');
    final response = await _client.post(
      uri,
      headers: await _jsonHeaders,
      body: jsonEncode(payload),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'FastAPI create review failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<List<Map<String, dynamic>>> fetchAssignedPetsForSitter(
    String sitterId,
  ) async {
    final uri = Uri.parse('$_baseUrl/sitting_jobs/sitter/$sitterId');
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode != 200) {
      throw Exception(
        'FastAPI fetch assigned pets failed (${response.statusCode})',
      );
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> fetchLatestBehaviorLog(String userId) async {
    final uri = Uri.parse(
      '$_baseUrl/behavior_logs/latest',
    ).replace(queryParameters: {'user_id': userId});
    final response = await _client.get(uri, headers: await _jsonHeaders);
    if (response.statusCode == 404) {
      return <String, dynamic>{};
    }
    if (response.statusCode != 200) {
      throw Exception(
        'FastAPI fetch latest behavior log failed (${response.statusCode})',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  String _dateOnly(DateTime value) => value.toIso8601String().split('T').first;

  Future<void> _persistToken(String token) async {
    _accessToken = token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }
}
