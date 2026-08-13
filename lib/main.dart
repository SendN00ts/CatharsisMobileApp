import 'dart:io';
import 'package:catharsis_cards/provider/auth_provider.dart';
import 'package:catharsis_cards/provider/theme_provider.dart';
import 'package:catharsis_cards/provider/user_profile_provider.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:catharsis_cards/services/notification_service.dart';
import 'package:catharsis_cards/services/subscription_service.dart';
import 'package:catharsis_cards/services/ad_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'questions_model.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'flutter_flow/flutter_flow_theme.dart';
import 'flutter_flow/flutter_flow_util.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:google_fonts/google_fonts.dart';
import 'index.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'provider/app_state_provider.dart';
import 'provider/pop_up_provider.dart';
import 'provider/tutorial_state_provider.dart';
import '/flutter_flow/flutter_flow_icon_button.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:go_router/go_router.dart';
import '/pages/profile/profile_page.dart';
import '/pages/home_page/home_page_widget.dart';
import '/pages/liked_cards/liked_cards_widget.dart';
import 'app_router.dart' as app_router;
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter/services.dart';
import 'provider/reflection_provider.dart';
import 'services/duo_questions_service.dart';
// import 'package:device_preview/device_preview.dart';

/// Singleton ChangeNotifier that wraps Firebase Auth state changes.
/// Used by GoRouter's [refreshListenable] so the router re-evaluates its
/// redirect guards whenever the user logs in or out.
class AppStateNotifier extends ChangeNotifier {
  static final AppStateNotifier _instance = AppStateNotifier._internal();
  factory AppStateNotifier() => _instance;
  static AppStateNotifier get instance => _instance;

  AppStateNotifier._internal() {
    FirebaseAuth.instance.authStateChanges().listen((user) {
      notifyListeners();
    });
  }
}

Future<void> _initAdsAndroid() async {
  await MobileAds.instance.initialize();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait — the card-swipe UI is portrait-only.
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Hide system UI bars for a full-screen immersive experience.
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.immersiveSticky,
  );

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // promptUser: false — we don't ask for notification permission at launch.
  // Request it contextually (e.g. when the user enables a streak reminder).
  await NotificationService.init(promptUser: false);

  // Register the tap handler before runApp so cold-start notification taps are caught.
  // Must be called after AwesomeNotifications().initialize() (done inside NotificationService.init).
  await AwesomeNotifications().setListeners(
    onActionReceivedMethod: NotificationService.onNotificationTapMethod,
  );

  await Hive.initFlutter();
  Hive.registerAdapter(QuestionAdapter()); // QuestionAdapter is generated — do not edit questions_model.g.dart by hand
  // Open the Circle mode question cache box at startup so it's available immediately
  // when the user enters duo mode, without a blocking async open at that point.
  await Hive.openBox<Question>(DuoQuestionsService.duoCacheBoxName);

  if (Platform.isAndroid) {
    await _initAdsAndroid();
  }

  runApp(
    // DevicePreview(
    //   enabled: !kReleaseMode, // Only in debug mode
    //   builder: (context) => ProviderScope(child: MyApp()),
    // ),
    ProviderScope(
      child: MyApp(),
    ),
  );
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({Key? key}) : super(key: key);
  @override
  ConsumerState<MyApp> createState() => _MyAppState();

  static _MyAppState of(BuildContext context) =>
      context.findAncestorStateOfType<_MyAppState>()!;
}

class _MyAppState extends ConsumerState<MyApp> {
  late AppStateNotifier _appStateNotifier;
  late GoRouter _router;

  @override
  void initState() {
    super.initState();
    _appStateNotifier = AppStateNotifier.instance;
    _router = app_router.createRouter(_appStateNotifier, ref);
    try {
      final subscriptionService = ref.read(subscriptionServiceProvider);
      AdService.initialize(subscriptionService);
    } catch (e) {
      // Silent fail
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeState = ref.watch(themeProvider);

    // Watch auth state changes to react to login and logout events.
    ref.listen<AsyncValue<User?>>(authStateProvider, (previous, next) {
      final previousUser = previous?.whenOrNull(data: (user) => user);
      final currentUser = next.whenOrNull(data: (user) => user);

      if (previousUser != null && currentUser == null) {
        // User just logged out — invalidate all user-specific providers so stale
        // data from the previous user's session doesn't bleed into the next one.
        // The small delay avoids calling setState during a build frame.
        Future.delayed(Duration(milliseconds: 100), () {
          if (mounted) {
            ref.invalidate(userProfileProvider);
            ref.invalidate(cardStateProvider);
            ref.invalidate(tutorialProvider);
            ref.read(reflectionProvider.notifier).reset();
          }
        });
      } else if (previousUser == null && currentUser != null) {
        // User just logged in — load their reflections from Firestore.
        ref.read(reflectionProvider.notifier).load();
      }

      // Trigger GoRouter to re-check redirect guards (login/logout routing).
      _router.refresh();
    });

    ref.listen<TutorialState>(tutorialProvider, (previous, next) {
      _router.refresh();
    });

    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'CatharsisCards',
      // locale: DevicePreview.locale(context),
      localizationsDelegates: [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en', '')],
      theme: themeState.themeData,
      darkTheme: themeState.themeData,
      themeMode: ThemeMode.light,
      routerConfig: _router,
      builder: (context, child) {
        return Container(
          // Fill system edge insets (notch, rounded corners) with the scaffold
          // background so there's no white flash during navigation transitions.
          color: Theme.of(context).scaffoldBackgroundColor,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              // Clamp text scale to 1.0–1.3 so the UI doesn't break at very
              // large accessibility text sizes, while still respecting user prefs.
              textScaleFactor: MediaQuery.of(context).textScaleFactor.clamp(1.0, 1.3),
            ),
            child: child!,
          ),
        );
      },
    );
  }
}

class NavBarPage extends ConsumerStatefulWidget {
  NavBarPage({Key? key, this.initialPage, this.page}) : super(key: key);
  final String? initialPage;
  final Widget? page;

  @override
  ConsumerState<NavBarPage> createState() => _NavBarPageState();
}

class _NavBarPageState extends ConsumerState<NavBarPage> {
  String _currentPageName = 'HomePage';
  late Widget? _currentPage;

  @override
  void initState() {
    super.initState();
    _currentPageName = widget.initialPage ?? _currentPageName;
    _currentPage = widget.page;
  }

  @override
  Widget build(BuildContext context) {
    final cardState = ref.watch(cardStateProvider);
    final notifier = ref.read(cardStateProvider.notifier);

    final tabs = {
      'HomePage': HomePageWidget(),
      'ProfilePage': ProfilePageWidget(),
      'LikedCards': LikedCardsWidget(),
    };
    final currentIndex = tabs.keys.toList().indexOf(_currentPageName);

    final isCurrentQuestionLiked = cardState.currentQuestion != null &&
        cardState.likedQuestions.any((q) =>
            q.text == cardState.currentQuestion!.text &&
            q.category == cardState.currentQuestion!.category);

    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Stack(
        children: [
          _currentPage ?? tabs[_currentPageName]!,
          if (_currentPageName == 'HomePage')
            Positioned(
              bottom: 80,
              left: 0,
              right: 0,
              child: Center(),
            ),
        ],
      ),
    );
  }
}

class DebugUtils {
  static Future<void> printAllPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    
    print('=== SharedPreferences Debug ===');
    print('Total keys: ${keys.length}');
    
    for (final key in keys) {
      final value = prefs.get(key);
      print('$key: $value');
    }
    print('==============================');
  }
  
  static Future<void> printTutorialStateForUser(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'has_seen_tutorial_$userId';
    final value = prefs.getBool(key);
    
    print('=== Tutorial State Debug ===');
    print('User ID: $userId');
    print('Key: $key');
    print('Value: $value');
    print('===========================');
  }
  
  static Future<void> clearAllTutorialStates() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    
    for (final key in keys) {
      if (key.startsWith('has_seen_tutorial_')) {
        await prefs.remove(key);
        print('Removed: $key');
      }
    }
  }
}