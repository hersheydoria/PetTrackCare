// fake_sign_in_with_apple/lib/sign_in_with_apple.dart

class SignInWithApple {
  static Future<dynamic> getAppleIDCredential({
    List<dynamic>? scopes,
    String? nonce, // ✅ Add this to match Supabase's call
  }) async {
    throw UnimplementedError('SignInWithApple is not supported on Android.');
  }
}

class AppleIDAuthorizationScopes {
  static const email = 'email';
  static const fullName = 'fullName';
}
