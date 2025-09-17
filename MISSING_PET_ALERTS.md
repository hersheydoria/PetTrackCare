# Missing Pet Alert System

## Overview
The Missing Pet Alert System provides real-time, app-wide alerts when pets are marked as missing. This ensures that all users receive immediate notifications and visual alerts, regardless of which screen they're currently viewing.

## Features

### 🚨 Real-time Alerts
- Monitors for new missing pet posts every 5 seconds
- Shows urgent alert dialogs immediately when a pet is reported missing
- Includes haptic feedback for urgency
- Only shows alerts for other users' pets (not your own)

### 📱 Smart Filtering
- Only shows alerts for posts created within the last 2 minutes (prevents old posts from triggering alerts)
- Avoids duplicate alerts for the same post
- Excludes alerts from the current user's own posts

### 🎨 Enhanced Alert Dialog
- Eye-catching red-themed urgent design
- Pet photo display
- Reporter name and timestamp
- Full post content
- Direct navigation to post details
- Non-dismissible initially to ensure visibility

## Implementation

### Global Service
The `MissingPetAlertService` is a singleton service that:
- Runs independently of any specific screen
- Maintains alert state across app navigation
- Can be paused/resumed as needed
- Automatically updates context when navigating

### Integration Options

#### Option 1: Wrap Main App (Recommended)
```dart
// In your main.dart or app widget
MaterialApp(
  home: MissingPetAlertWrapper(
    child: YourMainScreen(),
  ),
)
```

#### Option 2: Manual Integration
```dart
// In any screen where you want alerts
@override
void initState() {
  super.initState();
  MissingPetAlertService().initialize(context);
}

@override
void dispose() {
  MissingPetAlertService().dispose();
  super.dispose();
}
```

### Current Implementation
The system is now fully integrated app-wide! The `MissingPetAlertWrapper` is applied to all main routes in `main.dart`:

- **Main Navigation** (`/home`): Alerts active on all main app screens
- **Notifications** (`/notification`): Alerts active while viewing notifications  
- **Post Details** (`/postDetail`): Alerts active while viewing community posts
- **Pet Alerts** (`/petAlert`): Alerts active on pet alert screens
- **Profile Screens** (`/profile_owner`, `/profile_sitter`): Alerts active on profile pages
- **Location Picker** (`/location_picker`): Alerts active during location selection

**Excluded routes** (no alerts needed):
- Login and registration screens
- Password reset screen

This means users will receive missing pet alerts regardless of which screen they're currently viewing within the main app functionality.

## Database Requirements

The system expects the following database structure:

### community_posts table
- `id` (int): Post ID
- `type` (string): Post type ('missing', 'found', etc.)
- `user_id` (string): ID of user who posted
- `content` (string): Post content
- `image_url` (string): Pet photo URL
- `created_at` (timestamp): When post was created

### users table (joined)
- `name` (string): Name of the user who posted

## Notification Flow

1. **Pet Marked Missing**: When a pet is marked as missing in `pets_screen.dart`
2. **Post Created**: A community post is created with type 'missing'
3. **Service Detection**: The alert service detects the new post within 5 seconds
4. **Alert Display**: Shows urgent dialog to all other users
5. **User Action**: Users can dismiss or view full details

## Usage Examples

### Basic Alert
When a pet named "Buddy" is reported missing:
- Shows "🚨 MISSING PET ALERT" title
- Displays pet photo
- Shows "Pet: Buddy"
- Includes reporter name and time
- Shows full description
- Provides "View Details" button

### Navigation
- "Dismiss" button closes the alert
- "View Details" navigates to post detail screen (if route exists)
- Fallback shows snackbar with content if navigation fails

## Customization

### Alert Frequency
Change polling interval in `MissingPetAlertService`:
```dart
Timer.periodic(Duration(seconds: 5), ...)  // Currently 5 seconds
```

### Time Window
Modify recent post detection:
```dart
now.difference(createdAt).inMinutes <= 2  // Currently 2 minutes
```

### Alert Styling
Customize appearance in `_showGlobalMissingAlert()` method.

## Error Handling

- Gracefully handles network errors
- Continues monitoring even if individual requests fail
- Provides fallback navigation if routes don't exist
- Protects against missing data fields

## Performance Considerations

- Uses efficient database queries with limits
- Only fetches recent posts to minimize data transfer
- Caches last alert ID to prevent duplicates
- Automatically cleans up timers and resources

## Testing

To test the app-wide alert system:

### Basic Test
1. Have two user accounts logged in on different devices/browsers
2. With User A: Mark a pet as missing from any screen in the app
3. With User B: Navigate to any main app screen (home, notifications, profiles, etc.)
4. User B should see the urgent missing pet alert within 5 seconds
5. Alert should include pet details and allow navigation to post details

### App-Wide Test
1. With User B, navigate between different screens:
   - Main navigation/home screen
   - Notification screen
   - Profile screens
   - Post detail screens
2. The alert should appear regardless of which screen User B is currently viewing
3. Test that alerts don't show on login/registration screens (excluded routes)

### Alert Content Test
- Alert should display pet photo (if available)
- Should show pet name, reporter name, and timestamp
- Should include full post content in styled container
- Should provide "Dismiss" and "View Details" buttons
- Should include haptic feedback on supported devices

## Future Enhancements

Potential improvements:
- WebSocket/real-time subscriptions instead of polling
- Sound alerts with user preferences
- Location-based filtering (show alerts for nearby pets)
- Alert history and management
- Customizable alert settings per user