import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Manages the full in-app purchase lifecycle for Catharsis Cards.
///
/// Premium status is stored locally in SharedPreferences (not Firestore), so it
/// survives app restarts without a network call. On startup the service checks
/// the locally cached expiry timestamp, then calls restorePurchases() to sync
/// with the store backend in the background.
///
/// Product IDs must exactly match the ones configured in:
///   - Google Play Console → Subscriptions
///   - App Store Connect   → In-App Purchases
class SubscriptionService {
  // Product IDs differ between platforms — Android uses short IDs, iOS uses
  // reverse-domain style. Both sets must stay in sync with the store dashboards.
  Set<String> get _productIds {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return {
        'monthly_subscription',
        'annual_subscription',
      };
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      return {
        'com.catharsis.cards.monthly',
        'com.catharsis.cards.annual',
      };
    }
    return {};
  }

  // SharedPreferences keys for local premium state persistence.
  static const _kPremiumKey = 'is_premium';
  static const _kSubscriptionExpiryKey = 'subscription_expiry'; // epoch ms
  static const _kSubscriptionTypeKey = 'subscription_type';     // 'monthly' | 'annual'

  // ValueNotifier lets non-Riverpod code read the current premium state synchronously.
  final ValueNotifier<bool> isPremium = ValueNotifier<bool>(false);
  // Broadcast stream used by isPremiumProvider to push updates to Riverpod listeners.
  final StreamController<bool> _premiumStatusController = StreamController<bool>.broadcast();
  Stream<bool> get premiumStatusStream => _premiumStatusController.stream;

  List<ProductDetails> _products = [];
  StreamSubscription<List<PurchaseDetails>>? _subscription;
  bool _initialized = false;
  SharedPreferences? _prefs;

  /// Initialises the purchase system. Called once at app startup via [subscriptionServiceProvider].
  ///
  /// Order of operations:
  ///   1. Check locally cached expiry — grants premium instantly if still valid.
  ///   2. Open the store connection and query available products.
  ///   3. Listen to the purchase stream for new purchases / restores.
  ///   4. Call restorePurchases() to sync with the store (catches renewals, cross-device installs).
  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();

    // Check if subscription is still valid
    await _checkSubscriptionValidity();

    final available = await InAppPurchase.instance.isAvailable();
    if (!available) {
      _initialized = true;
      return;
    }

    final response = await InAppPurchase.instance.queryProductDetails(_productIds);
    _products = response.productDetails;

    _subscription = InAppPurchase.instance.purchaseStream.listen(
      _listenToPurchaseUpdated,
      onDone: () => _subscription?.cancel(),
      onError: (Object _, __) {},
    );

    // Restore purchases to verify subscription status
    await InAppPurchase.instance.restorePurchases();

    _initialized = true;
  }

  Future<void> _checkSubscriptionValidity() async {
    final expiryTimestamp = _prefs?.getInt(_kSubscriptionExpiryKey);
    if (expiryTimestamp != null) {
      final expiryDate = DateTime.fromMillisecondsSinceEpoch(expiryTimestamp);
      if (DateTime.now().isBefore(expiryDate)) {
        isPremium.value = true;
        await _prefs?.setBool(_kPremiumKey, true);
        // Emit to the stream so isPremiumProvider transitions out of AsyncLoading
        _premiumStatusController.add(true);
      } else {
        // Subscription expired
        await _revokeSubscription();
      }
    } else {
      final cached = _prefs?.getBool(_kPremiumKey) ?? false;
      isPremium.value = cached;
      // Always emit so the provider resolves immediately with the correct value
      _premiumStatusController.add(cached);
    }
  }

  Future<void> _grantSubscription({Duration? duration, String? productId}) async {
    isPremium.value = true;
    await _prefs?.setBool(_kPremiumKey, true);
    
    // Store subscription type based on product ID
    if (productId != null) {
      String subscriptionType = 'unknown';
      if (productId.contains('monthly')) {
        subscriptionType = 'monthly';
      } else if (productId.contains('annual')) {
        subscriptionType = 'annual';
      }
      await _prefs?.setString(_kSubscriptionTypeKey, subscriptionType);
    }
    
    // Set expiry date if duration provided (for subscriptions)
    if (duration != null) {
      final expiry = DateTime.now().add(duration);
      await _prefs?.setInt(_kSubscriptionExpiryKey, expiry.millisecondsSinceEpoch);
    }
    
    // Notify listeners that premium status changed
    _premiumStatusController.add(true);
  }

  Future<void> _revokeSubscription() async {
    isPremium.value = false;
    await _prefs?.setBool(_kPremiumKey, false);
    await _prefs?.remove(_kSubscriptionExpiryKey);
    await _prefs?.remove(_kSubscriptionTypeKey);
    _premiumStatusController.add(false);
  }

  /// Handles incoming purchase events from the platform store.
  ///
  /// This fires for:
  ///   - New purchases the user just completed
  ///   - Restored purchases (from restorePurchases())
  ///   - Subscription renewals
  ///
  /// Every successful purchase must be acknowledged (completePurchase) within
  /// 3 days or Google Play will automatically refund it.
  void _listenToPurchaseUpdated(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      switch (purchase.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // Determine subscription duration based on product ID
          if (purchase.productID.contains('monthly')) {
            subscriptionDuration = Duration(days: 30);
          } else if (purchase.productID.contains('annual') || purchase.productID.contains('yearly')) {
            subscriptionDuration = Duration(days: 365);
          }
          
          await _grantSubscription(
            duration: subscriptionDuration,
            productId: purchase.productID,
          );
          
          if (purchase.pendingCompletePurchase) {
            await InAppPurchase.instance.completePurchase(purchase);
          }
          break;
        case PurchaseStatus.error:
        case PurchaseStatus.canceled:
        case PurchaseStatus.pending:
          break;
      }
    }
  }

  ProductDetails? productById(String id) {
    for (final product in _products) {
      if (product.id == id) return product;
    }
    return null;
  }

  Future<void> purchase(String id) async {
    if (!_initialized) await init();
    final product = productById(id);
    if (product == null) throw Exception('Product $id not found');
    final param = PurchaseParam(productDetails: product);
    await InAppPurchase.instance.buyNonConsumable(purchaseParam: param);
  }

  bool isUserSubscribed() {
    final expiryTimestamp = _prefs?.getInt(_kSubscriptionExpiryKey);
    if (expiryTimestamp != null) {
      final expiryDate = DateTime.fromMillisecondsSinceEpoch(expiryTimestamp);
      return DateTime.now().isBefore(expiryDate);
    }
    return _prefs?.getBool(_kPremiumKey) ?? false;
  }

  Future<bool> isUserSubscribedAsync() async {
    final expiryTimestamp = _prefs?.getInt(_kSubscriptionExpiryKey);
    if (expiryTimestamp != null) {
      final expiryDate = DateTime.fromMillisecondsSinceEpoch(expiryTimestamp);
      return DateTime.now().isBefore(expiryDate);
    }
    return _prefs?.getBool(_kPremiumKey) ?? false;
  }

  // Get the current subscription type (monthly, annual, or none)
  String? getCurrentSubscriptionType() {
    if (!isUserSubscribed()) return null;
    return _prefs?.getString(_kSubscriptionTypeKey);
  }

  // Get subscription expiry date
  DateTime? getSubscriptionExpiry() {
    final expiryTimestamp = _prefs?.getInt(_kSubscriptionExpiryKey);
    if (expiryTimestamp != null) {
      return DateTime.fromMillisecondsSinceEpoch(expiryTimestamp);
    }
    return null;
  }

  void dispose() {
    _subscription?.cancel();
    _premiumStatusController.close();
  }
}

// Singleton provider — one SubscriptionService instance for the entire app lifetime.
final subscriptionServiceProvider = Provider<SubscriptionService>((ref) {
  final service = SubscriptionService();
  service.init();
  ref.onDispose(() => service.dispose());
  return service;
});

// Riverpod provider for premium status. Widgets watch this to gate premium features.
//
// Uses an async* generator so it can yield the already-known cached value from
// the ValueNotifier immediately — this prevents a brief AsyncLoading flash that
// would default to non-premium (showing paywalls to subscribers on every cold start).
// After the initial emit, all future changes (purchases, restores, revocations) come
// through the broadcast stream.
final isPremiumProvider = StreamProvider<bool>((ref) async* {
  final service = ref.watch(subscriptionServiceProvider);
  // Emit the currently cached value right away — no waiting for the stream.
  yield service.isPremium.value;
  // Then yield all future updates (purchases, restores, revocations).
  yield* service.premiumStatusStream;
});