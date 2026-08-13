import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/duo_session.dart';
import '../questions_model.dart';

/// Manages Firestore reads/writes for duo/group sessions.
class DuoSessionService {
  static final _db = FirebaseFirestore.instance;
  static const _col = 'duoSessions';

  // ── Session code ────────────────────────────────────────────────────────────

  /// Generates a random 6-character session code used as the Firestore document ID.
  /// Characters that look similar (I, O, 0, 1) are excluded to reduce user entry errors.
  static String generateCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    return List.generate(6, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  // ── Create ──────────────────────────────────────────────────────────────────

  /// Creates a new duo/group session with [questions] as the card deck.
  /// [maxPlayers] controls group size (2 = classic duo, 3-4 = group mode).
  /// [reserves] are spare questions used to replace skipped cards.
  static Future<String> createSession({
    required String hostUid,
    required String hostName,
    required List<Question> questions,
    List<Question> reserves = const [],
    int maxPlayers = 2,
  }) async {
    final code = generateCode();
    final cards = questions
        .map((q) => DuoCard(
              questionText: q.text,
              questionCategory: q.category,
            ))
        .toList();

    final reserveCards = reserves
        .map((q) => {'text': q.text, 'category': q.category})
        .toList();

    final session = DuoSession(
      sessionCode: code,
      hostUid: hostUid,
      hostName: hostName,
      status: DuoSessionStatus.waiting,
      cards: cards,
      createdAt: DateTime.now(),
      reserveCards: reserveCards,
      maxPlayers: maxPlayers,
      // Host is the first participant
      participants: {hostUid: hostName},
      // Each player in a group session gets their own skip budget.
      // For classic 2-player sessions this map stays empty and the legacy
      // hostSkipsLeft/guestSkipsLeft fields are used instead.
      playerSkipsLeft: maxPlayers > 2 ? {hostUid: 3} : {},
    );

    await _db.collection(_col).doc(code).set(session.toMap());
    return code;
  }

  // ── Join ────────────────────────────────────────────────────────────────────

  /// Joins an existing session.
  ///
  /// For 2-player sessions: sets guestUid/guestName and auto-starts the session.
  /// For group sessions: adds the player to [participants] and auto-starts only
  /// when the session reaches [maxPlayers]. The host can also start manually via
  /// [startSession].
  static Future<DuoSession> joinSession({
    required String code,
    required String guestUid,
    required String guestName,
  }) async {
    final ref = _db.collection(_col).doc(code.toUpperCase().trim());
    final snap = await ref.get();

    if (!snap.exists) {
      throw Exception('Session not found. Check the code and try again.');
    }

    final session = DuoSession.fromDoc(snap);

    if (session.status != DuoSessionStatus.waiting) {
      throw Exception('This session has already started or ended.');
    }

    if (session.hostUid == guestUid) {
      throw Exception('You cannot join your own session.');
    }

    if (session.participants.containsKey(guestUid)) {
      // If the session is still waiting, the player is already in the lobby
      // (e.g. they rejoined after an unclean disconnect). Just route them in.
      if (session.status == DuoSessionStatus.waiting) return session;
      throw Exception('This session has already started or ended.');
    }

    // Build the updated participants map
    final updatedParticipants = {...session.participants, guestUid: guestName};
    final willBeFull = updatedParticipants.length >= session.maxPlayers;

    if (session.maxPlayers == 2) {
      // Classic duo: set guest fields and immediately start
      await ref.update({
        'guestUid': guestUid,
        'guestName': guestName,
        'participants': updatedParticipants,
        'status': DuoSessionStatus.active.name,
      });
    } else {
      // Group: track participant; auto-start only if the group is now full.
      // Give the new player their own skip budget.
      final updatedSkips = {
        ...session.playerSkipsLeft,
        guestUid: 3,
      };
      final Map<String, dynamic> update = {
        'participants': updatedParticipants,
        'playerSkipsLeft': updatedSkips,
        if (willBeFull) 'status': DuoSessionStatus.active.name,
        // Store first non-host joiner as guestUid for backward compat
        if (!session.hasGuest) 'guestUid': guestUid,
        if (!session.hasGuest) 'guestName': guestName,
      };
      await ref.update(update);
    }

    final updated = await ref.get();
    return DuoSession.fromDoc(updated);
  }

  // ── Leave (waiting room) ────────────────────────────────────────────────────

  /// Called when a player navigates away from the waiting room before the
  /// session starts.
  ///
  /// - Host leaving → session is cancelled for everyone.
  /// - Non-host leaving → their entry is removed from [participants] so the
  ///   live lobby updates instantly for remaining players. If they were stored
  ///   as [guestUid], that field is also cleared so the slot is re-joinable.
  static Future<void> leaveSession({
    required String code,
    required String uid,
    required bool isHost,
  }) async {
    final docRef = _db.collection(_col).doc(code);
    if (isHost) {
      await docRef.update({'status': DuoSessionStatus.cancelled.name});
    } else {
      await _db.runTransaction((tx) async {
        final snap = await tx.get(docRef);
        if (!snap.exists) return;
        final data = snap.data() as Map<String, dynamic>;
        if ((data['status'] as String?) != DuoSessionStatus.waiting.name) return;

        final participants = Map<String, dynamic>.from(
            data['participants'] as Map? ?? {});
        participants.remove(uid);

        final Map<String, dynamic> update = {'participants': participants};
        // Clear guestUid/guestName if this was the first non-host joiner,
        // so the slot can be reused by someone else.
        if ((data['guestUid'] as String?) == uid) {
          update['guestUid'] = null;
          update['guestName'] = null;
        }
        tx.update(docRef, update);
      });
    }
  }

  // ── Start (group mode) ──────────────────────────────────────────────────────

  /// Manually starts a group session. Called by the host from the waiting room
  /// when they decide to begin even if not all players have joined.
  /// No-op if the session has already started or is not in waiting state.
  static Future<void> startSession(String code) async {
    final ref = _db.collection(_col).doc(code);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;
      final data = snap.data() as Map<String, dynamic>;
      if ((data['status'] as String?) != DuoSessionStatus.waiting.name) return;
      // Need at least 2 players to start
      final participants = data['participants'];
      final count = participants is Map ? participants.length : 0;
      if (count < 2) return;
      tx.update(ref, {'status': DuoSessionStatus.active.name});
    });
  }

  // ── Stream ──────────────────────────────────────────────────────────────────

  /// Returns a real-time stream of the session document.
  /// All active players listen to this — when any player writes to Firestore
  /// (submitting a reflection, voting, skipping), all other clients update instantly.
  /// Returns null when the document doesn't exist (e.g. invalid code).
  static Stream<DuoSession?> streamSession(String code) {
    return _db
        .collection(_col)
        .doc(code.toUpperCase().trim())
        .snapshots()
        .map((snap) => snap.exists ? DuoSession.fromDoc(snap) : null);
  }

  // ── Swipe ───────────────────────────────────────────────────────────────────

  static Future<void> recordSwipe({
    required String code,
    required int cardIndex,
    required bool isHost,
    required String swipe,
  }) async {
    final field = isHost
        ? 'cards.$cardIndex.hostSwipe'
        : 'cards.$cardIndex.guestSwipe';
    await _db.collection(_col).doc(code).update({field: swipe});
  }

  // ── Complete / Cancel session ───────────────────────────────────────────────

  static Future<void> completeSession(String code) async {
    await _db.collection(_col).doc(code).update({
      'status': DuoSessionStatus.complete.name,
    });
  }

  static Future<void> cancelSession(String code) async {
    await _db.collection(_col).doc(code).update({
      'status': DuoSessionStatus.cancelled.name,
    });
  }

  // ── Reflection (duo 2-player) ───────────────────────────────────────────────

  /// Saves a player's reflection for [cardIndex] in a 2-player session.
  static Future<void> saveReflection({
    required String code,
    required int cardIndex,
    required bool isHost,
    required String text,
  }) async {
    final field = isHost
        ? 'cards.$cardIndex.hostReflection'
        : 'cards.$cardIndex.guestReflection';
    await _db.collection(_col).doc(code).update({field: text.trim()});
  }

  // ── Reflection (group mode) ─────────────────────────────────────────────────

  /// Saves a player's reflection in a group session (indexed by uid).
  static Future<void> savePlayerReflection({
    required String code,
    required int cardIndex,
    required String uid,
    required String text,
  }) async {
    await _db
        .collection(_col)
        .doc(code)
        .update({'cards.$cardIndex.playerReflections.$uid': text.trim()});
  }

  // ── Past sessions ───────────────────────────────────────────────────────────

  /// Fetches all completed sessions the user participated in.
  ///
  /// Two queries are needed (host + guest) because Firestore doesn't support
  /// OR queries on different fields. Results are merged using a map (keyed by
  /// session code) to deduplicate any edge cases.
  ///
  /// Sessions the user has hidden (soft-deleted) are filtered out client-side.
  static Future<List<DuoSession>> fetchPastSessions(String uid,
      {int limit = 30}) async {
    final hostSnap = await _db
        .collection(_col)
        .where('hostUid', isEqualTo: uid)
        .where('status', isEqualTo: 'complete')
        .get();

    final guestSnap = await _db
        .collection(_col)
        .where('guestUid', isEqualTo: uid)
        .where('status', isEqualTo: 'complete')
        .get();

    final map = <String, DuoSession>{};
    for (final doc in [...hostSnap.docs, ...guestSnap.docs]) {
      final s = DuoSession.fromDoc(doc);
      map[s.sessionCode] = s;
    }

    return map.values
        .where((s) => !s.hiddenBy.contains(uid))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  // ── Hide session ─────────────────────────────────────────────────────────────

  /// Soft-deletes a session for one user by adding their UID to [hiddenBy].
  ///
  /// The Firestore document is NOT deleted — only filtered out of this user's
  /// history queries. The partner's session history is completely unaffected.
  /// FieldValue.arrayUnion ensures this is idempotent (safe to call twice).
  static Future<void> hideSession({
    required String code,
    required String uid,
  }) async {
    await _db.collection(_col).doc(code).update({
      'hiddenBy': FieldValue.arrayUnion([uid]),
    });
  }

  // ── Skip card ───────────────────────────────────────────────────────────────

  /// Replaces the question at [cardIndex] with the next reserve question and
  /// decrements the skipper's skip count. Uses a transaction for atomicity.
  ///
  /// For group sessions pass [uid] — the player's own skip count in
  /// [playerSkipsLeft] is decremented.  For classic 2-player sessions leave
  /// [uid] null and use [isHost] as before.
  static Future<void> skipCard({
    required String code,
    required int cardIndex,
    required bool isHost,
    String? uid,
  }) async {
    final ref = _db.collection(_col).doc(code);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) return;

      final data = snap.data() as Map<String, dynamic>;
      final reservesRaw = data['reserveCards'];
      if (reservesRaw is! List || (reservesRaw).isEmpty) return;

      final reserves = reservesRaw
          .cast<Map>()
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
      final replacement = reserves.removeAt(0);

      final Map<String, dynamic> updateFields = {
        'cards.$cardIndex.questionText': replacement['text'] ?? '',
        'cards.$cardIndex.questionCategory': replacement['category'] ?? '',
        'cards.$cardIndex.hostReflection': '',
        'cards.$cardIndex.guestReflection': '',
        'cards.$cardIndex.hostMatchChoice': FieldValue.delete(),
        'cards.$cardIndex.guestMatchChoice': FieldValue.delete(),
        'cards.$cardIndex.hostSwipe': FieldValue.delete(),
        'cards.$cardIndex.guestSwipe': FieldValue.delete(),
        'cards.$cardIndex.isSkipped': false,
        'cards.$cardIndex.playerReflections': {},
        'cards.$cardIndex.playerVotes': {},
        'reserveCards': reserves,
      };

      if (uid != null) {
        // Group mode: each player has their own budget in playerSkipsLeft.
        final skipsRaw = data['playerSkipsLeft'];
        final skipsMap = skipsRaw is Map
            ? Map<String, dynamic>.from(skipsRaw)
            : <String, dynamic>{};
        final currentSkips = (skipsMap[uid] as int?) ?? 0;
        if (currentSkips <= 0) return;
        updateFields['playerSkipsLeft.$uid'] = currentSkips - 1;
      } else {
        // Classic 2-player mode.
        final skipsField = isHost ? 'hostSkipsLeft' : 'guestSkipsLeft';
        final currentSkips = data[skipsField] as int? ?? 0;
        if (currentSkips <= 0) return;
        updateFields[skipsField] = currentSkips - 1;
      }

      tx.update(ref, updateFields);
    });
  }

  // ── Match choice (duo 2-player) ─────────────────────────────────────────────

  /// Records a player's explicit match/differ choice in a 2-player session.
  static Future<void> recordMatchChoice({
    required String code,
    required int cardIndex,
    required bool isHost,
    required String choice,
  }) async {
    final field = isHost
        ? 'cards.$cardIndex.hostMatchChoice'
        : 'cards.$cardIndex.guestMatchChoice';
    await _db.collection(_col).doc(code).update({field: choice});
  }

  // ── Player vote (group mode) ────────────────────────────────────────────────

  /// Records a player's vote in a group session (indexed by uid).
  /// [choice] must be 'matched' or 'differed'.
  static Future<void> recordPlayerVote({
    required String code,
    required int cardIndex,
    required String uid,
    required String choice,
  }) async {
    await _db
        .collection(_col)
        .doc(code)
        .update({'cards.$cardIndex.playerVotes.$uid': choice});
  }
}
