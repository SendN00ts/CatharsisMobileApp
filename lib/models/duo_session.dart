import 'package:cloud_firestore/cloud_firestore.dart';

enum DuoSessionStatus { waiting, active, complete, cancelled }

/// A single card in a duo/group session.
/// New flow: players write reflections, then explicitly choose 'matched'/'differed'.
/// Legacy flow (old sessions): match was inferred from hostSwipe == guestSwipe.
class DuoCard {
  final String questionText;
  final String questionCategory;

  // ── Legacy swipe fields (kept for backward-compat reading old sessions) ──
  final String? hostSwipe;   // 'like' | 'pass' | null
  final String? guestSwipe;

  // ── Duo (2-player) flow fields ──────────────────────────────────────────
  final String hostReflection;
  final String guestReflection;
  final String? hostMatchChoice;  // 'matched' | 'differed' | null
  final String? guestMatchChoice;

  // ── Group (3-4 player) flow fields ──────────────────────────────────────
  /// uid → reflection text (used in group sessions, maxPlayers > 2)
  final Map<String, String> playerReflections;
  /// uid → 'matched' | 'differed' (used in group sessions)
  final Map<String, String> playerVotes;

  /// True when either player has tapped Skip — card is skipped for both.
  final bool isSkipped;

  const DuoCard({
    required this.questionText,
    required this.questionCategory,
    this.hostSwipe,
    this.guestSwipe,
    this.hostReflection = '',
    this.guestReflection = '',
    this.hostMatchChoice,
    this.guestMatchChoice,
    this.isSkipped = false,
    this.playerReflections = const {},
    this.playerVotes = const {},
  });

  // ── Duo (2-player) derived state ─────────────────────────────────────────

  bool get reflectionsComplete =>
      hostReflection.isNotEmpty && guestReflection.isNotEmpty;

  /// Card fully done for duo mode. Skipped cards are always complete.
  bool get isComplete {
    if (isSkipped) return true;
    if (hostMatchChoice != null || guestMatchChoice != null) {
      return reflectionsComplete &&
          hostMatchChoice != null &&
          guestMatchChoice != null;
    }
    return hostSwipe != null && guestSwipe != null;
  }

  bool get isMatch {
    if (hostMatchChoice != null || guestMatchChoice != null) {
      return isComplete &&
          hostMatchChoice == 'matched' &&
          guestMatchChoice == 'matched';
    }
    return isComplete && hostSwipe == guestSwipe;
  }

  bool get bothDiffered =>
      isComplete &&
      hostMatchChoice == 'differed' &&
      guestMatchChoice == 'differed';

  bool get hasMixedVote =>
      isComplete && !isMatch && !bothDiffered && hostMatchChoice != null;

  bool get isSplit => isComplete && !isMatch;

  String? get hostDecision => hostMatchChoice ?? hostSwipe;
  String? get guestDecision => guestMatchChoice ?? guestSwipe;

  // ── Group (3-4 player) derived state ────────────────────────────────────

  bool reflectionsCompleteForGroup(List<String> uids) =>
      uids.isNotEmpty &&
      uids.every((uid) => (playerReflections[uid] ?? '').isNotEmpty);

  bool isCompleteForGroup(List<String> uids) {
    if (isSkipped) return true;
    if (uids.isEmpty) return false;
    return uids.every((uid) => playerVotes.containsKey(uid));
  }

  bool isMatchForGroup(List<String> uids) =>
      isCompleteForGroup(uids) &&
      uids.every((uid) => playerVotes[uid] == 'matched');

  bool allDifferedForGroup(List<String> uids) =>
      isCompleteForGroup(uids) &&
      uids.every((uid) => playerVotes[uid] == 'differed');

  bool hasMixedVoteForGroup(List<String> uids) =>
      isCompleteForGroup(uids) &&
      !isMatchForGroup(uids) &&
      !allDifferedForGroup(uids);

  // ── Serialization ────────────────────────────────────────────────────────

  DuoCard copyWith({
    String? hostSwipe,
    String? guestSwipe,
    String? hostReflection,
    String? guestReflection,
    String? hostMatchChoice,
    String? guestMatchChoice,
    bool? isSkipped,
    Map<String, String>? playerReflections,
    Map<String, String>? playerVotes,
  }) =>
      DuoCard(
        questionText: questionText,
        questionCategory: questionCategory,
        hostSwipe: hostSwipe ?? this.hostSwipe,
        guestSwipe: guestSwipe ?? this.guestSwipe,
        hostReflection: hostReflection ?? this.hostReflection,
        guestReflection: guestReflection ?? this.guestReflection,
        hostMatchChoice: hostMatchChoice ?? this.hostMatchChoice,
        guestMatchChoice: guestMatchChoice ?? this.guestMatchChoice,
        isSkipped: isSkipped ?? this.isSkipped,
        playerReflections: playerReflections ?? this.playerReflections,
        playerVotes: playerVotes ?? this.playerVotes,
      );

  Map<String, dynamic> toMap() => {
        'questionText': questionText,
        'questionCategory': questionCategory,
        'hostSwipe': hostSwipe,
        'guestSwipe': guestSwipe,
        'hostReflection': hostReflection,
        'guestReflection': guestReflection,
        'hostMatchChoice': hostMatchChoice,
        'guestMatchChoice': guestMatchChoice,
        'isSkipped': isSkipped,
        'playerReflections': playerReflections,
        'playerVotes': playerVotes,
      };

  factory DuoCard.fromMap(Map<String, dynamic> m) => DuoCard(
        questionText: m['questionText'] as String? ?? '',
        questionCategory: m['questionCategory'] as String? ?? '',
        hostSwipe: m['hostSwipe'] as String?,
        guestSwipe: m['guestSwipe'] as String?,
        hostReflection: m['hostReflection'] as String? ?? '',
        guestReflection: m['guestReflection'] as String? ?? '',
        hostMatchChoice: m['hostMatchChoice'] as String?,
        guestMatchChoice: m['guestMatchChoice'] as String?,
        isSkipped: m['isSkipped'] as bool? ?? false,
        playerReflections: _parseStringMap(m['playerReflections']),
        playerVotes: _parseStringMap(m['playerVotes']),
      );

  static Map<String, String> _parseStringMap(dynamic raw) {
    if (raw is! Map) return const {};
    return Map<String, String>.fromEntries(
      raw.entries
          .where((e) => e.value is String)
          .map((e) => MapEntry(e.key.toString(), e.value as String)),
    );
  }
}

/// The full duo/group session document stored in Firestore at duoSessions/{sessionCode}.
class DuoSession {
  final String sessionCode;
  final String hostUid;
  final String hostName;
  final String? guestUid;
  final String? guestName;
  final DuoSessionStatus status;
  final List<DuoCard> cards;
  final DateTime createdAt;
  /// UIDs of users who have hidden this session from their own history.
  final List<String> hiddenBy;
  /// Skips remaining for each player. Each player starts with 3.
  final int hostSkipsLeft;
  final int guestSkipsLeft;
  /// Pool of spare questions used to replace skipped cards.
  final List<Map<String, String>> reserveCards;

  // ── Group mode fields ────────────────────────────────────────────────────
  /// Maximum number of players for this session (2, 3, or 4).
  final int maxPlayers;
  /// uid → display name for all participants (including host).
  /// Populated for all new sessions; empty for legacy sessions.
  final Map<String, String> participants;
  /// uid → skips remaining. Used in group sessions so each player
  /// has their own independent skip budget (default 3 each).
  /// Empty for classic 2-player sessions (those use hostSkipsLeft/guestSkipsLeft).
  final Map<String, int> playerSkipsLeft;

  const DuoSession({
    required this.sessionCode,
    required this.hostUid,
    required this.hostName,
    this.guestUid,
    this.guestName,
    required this.status,
    required this.cards,
    required this.createdAt,
    this.hiddenBy = const [],
    this.hostSkipsLeft = 3,
    this.guestSkipsLeft = 3,
    this.reserveCards = const [],
    this.maxPlayers = 2,
    this.participants = const {},
    this.playerSkipsLeft = const {},
  });

  // ── Basic derived state ──────────────────────────────────────────────────

  bool get hasGuest => guestUid != null && guestUid!.isNotEmpty;
  bool get isWaiting => status == DuoSessionStatus.waiting;
  bool get isActive => status == DuoSessionStatus.active;
  bool get isComplete => status == DuoSessionStatus.complete;

  // ── Group mode ───────────────────────────────────────────────────────────

  bool get isGroupMode => maxPlayers > 2;

  List<String> get participantUids => participants.keys.toList();

  /// Returns the number of players who have currently joined.
  int get joinedCount => isGroupMode ? participants.length : (hasGuest ? 2 : 1);

  /// True when all expected players have joined (for group sessions).
  bool get groupIsFull => participants.length >= maxPlayers;

  // ── Card completion (group-aware) ────────────────────────────────────────

  bool cardIsComplete(int cardIdx) {
    if (cardIdx < 0 || cardIdx >= cards.length) return true;
    final card = cards[cardIdx];
    if (isGroupMode) return card.isCompleteForGroup(participantUids);
    return card.isComplete;
  }

  /// Index of the first card not yet fully completed by all players.
  /// Returns -1 when all cards are done.
  int get currentCardIndex {
    for (int i = 0; i < cards.length; i++) {
      if (!cardIsComplete(i)) return i;
    }
    return -1;
  }

  bool get allCardsComplete => currentCardIndex == -1;

  List<DuoCard> get matchedCards {
    if (isGroupMode) {
      final uids = participantUids;
      return cards.where((c) => c.isMatchForGroup(uids)).toList();
    }
    return cards.where((c) => c.isMatch).toList();
  }

  List<DuoCard> get splitCards {
    if (isGroupMode) {
      final uids = participantUids;
      return cards
          .where((c) => c.isCompleteForGroup(uids) && !c.isMatchForGroup(uids))
          .toList();
    }
    return cards.where((c) => c.isSplit).toList();
  }

  // ── Serialization ────────────────────────────────────────────────────────

  DuoSession copyWith({
    String? guestUid,
    String? guestName,
    DuoSessionStatus? status,
    List<DuoCard>? cards,
    List<String>? hiddenBy,
    int? hostSkipsLeft,
    int? guestSkipsLeft,
    List<Map<String, String>>? reserveCards,
    int? maxPlayers,
    Map<String, String>? participants,
    Map<String, int>? playerSkipsLeft,
  }) =>
      DuoSession(
        sessionCode: sessionCode,
        hostUid: hostUid,
        hostName: hostName,
        guestUid: guestUid ?? this.guestUid,
        guestName: guestName ?? this.guestName,
        status: status ?? this.status,
        cards: cards ?? this.cards,
        createdAt: createdAt,
        hiddenBy: hiddenBy ?? this.hiddenBy,
        hostSkipsLeft: hostSkipsLeft ?? this.hostSkipsLeft,
        guestSkipsLeft: guestSkipsLeft ?? this.guestSkipsLeft,
        reserveCards: reserveCards ?? this.reserveCards,
        maxPlayers: maxPlayers ?? this.maxPlayers,
        participants: participants ?? this.participants,
        playerSkipsLeft: playerSkipsLeft ?? this.playerSkipsLeft,
      );

  Map<String, dynamic> toMap() => {
        'hostUid': hostUid,
        'hostName': hostName,
        'guestUid': guestUid,
        'guestName': guestName,
        'status': status.name,
        'hiddenBy': hiddenBy,
        'hostSkipsLeft': hostSkipsLeft,
        'guestSkipsLeft': guestSkipsLeft,
        'reserveCards': reserveCards,
        'maxPlayers': maxPlayers,
        'participants': participants,
        'playerSkipsLeft': playerSkipsLeft,
        // Cards are stored as a Firestore map keyed by string index ("0", "1", "2"…)
        // rather than an array. This allows atomic field-level updates using dot notation
        // (e.g. "cards.2.hostMatchChoice") without rewriting the entire array,
        // which is critical for real-time multi-user concurrency.
        'cards': {
          for (int i = 0; i < cards.length; i++) '$i': cards[i].toMap(),
        },
        'createdAt': Timestamp.fromDate(createdAt),
      };

  factory DuoSession.fromDoc(DocumentSnapshot doc) {
    final m = doc.data() as Map<String, dynamic>;

    final cardsRaw = m['cards'];
    List<DuoCard> rawCards;
    if (cardsRaw is Map) {
      final sorted = cardsRaw.entries.toList()
        ..sort((a, b) => int.parse(a.key).compareTo(int.parse(b.key)));
      rawCards = sorted
          .map((e) => DuoCard.fromMap(Map<String, dynamic>.from(e.value as Map)))
          .toList();
    } else if (cardsRaw is List) {
      rawCards = cardsRaw
          .map((c) => DuoCard.fromMap(Map<String, dynamic>.from(c as Map)))
          .toList();
    } else {
      rawCards = [];
    }

    final statusStr = m['status'] as String? ?? 'waiting';
    final hiddenByRaw = m['hiddenBy'];
    final hiddenBy = hiddenByRaw is List
        ? hiddenByRaw.map((e) => e as String).toList()
        : <String>[];

    return DuoSession(
      sessionCode: doc.id,
      hostUid: m['hostUid'] as String? ?? '',
      hostName: m['hostName'] as String? ?? 'Host',
      guestUid: m['guestUid'] as String?,
      guestName: m['guestName'] as String?,
      status: DuoSessionStatus.values.firstWhere(
        (s) => s.name == statusStr,
        orElse: () => DuoSessionStatus.waiting,
      ),
      cards: rawCards,
      createdAt: (m['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      hiddenBy: hiddenBy,
      hostSkipsLeft: m['hostSkipsLeft'] as int? ?? 3,
      guestSkipsLeft: m['guestSkipsLeft'] as int? ?? 3,
      reserveCards: _parseReserves(m['reserveCards']),
      maxPlayers: m['maxPlayers'] as int? ?? 2,
      participants: _parseParticipants(m['participants']),
      playerSkipsLeft: _parsePlayerSkips(m['playerSkipsLeft']),
    );
  }

  static List<Map<String, String>> _parseReserves(dynamic raw) {
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => {
              'text': (e['text'] ?? '') as String,
              'category': (e['category'] ?? '') as String,
            })
        .where((e) => e['text']!.isNotEmpty)
        .toList();
  }

  static Map<String, String> _parseParticipants(dynamic raw) {
    if (raw is! Map) return const {};
    return Map<String, String>.fromEntries(
      raw.entries
          .where((e) => e.value is String)
          .map((e) => MapEntry(e.key.toString(), e.value as String)),
    );
  }

  static Map<String, int> _parsePlayerSkips(dynamic raw) {
    if (raw is! Map) return const {};
    return Map<String, int>.fromEntries(
      raw.entries
          .where((e) => e.value is int)
          .map((e) => MapEntry(e.key.toString(), e.value as int)),
    );
  }
}
