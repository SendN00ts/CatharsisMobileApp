import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../questions_model.dart';

/// Generates AI-powered questions by calling the `generateQuestions` Firebase Cloud Function.
///
/// The Cloud Function calls the OpenAI API server-side using the OPENAI_API_KEY stored
/// in the Function's environment variables. The key never ships inside the app binary.
///
/// The function accepts { category, count } and returns { questions: [string, ...] }.
/// Returned strings are cleaned (bullets/numbering stripped) before being wrapped
/// in Question objects.
class OpenAIService {
  static Future<List<Question>> generateQuestions({
    required String category,
    int count = 5,
  }) async {
    // Backstop auth check — callers should already have waited for auth,
    // but guard here too to make the error message more useful.
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('[OpenAI] Cannot call function: no authenticated user.');
    }

    try {
      final callable = FirebaseFunctions.instance
          .httpsCallable('generateQuestions');

      final result = await callable.call<Map<String, dynamic>>({
        'category': category,
        'count': count,
      });

      final rawList = result.data['questions'] as List<dynamic>? ?? [];
      return rawList
          .cast<String>()
          .map((raw) {
            // Strip leading bullets/dashes in case the model included them
            // despite instructions ("- Do you..." → "Do you...")
            final text = raw
                .trim()
                .replaceFirst(RegExp(r'^[\d]+\.?\s*'), '')
                .replaceFirst(RegExp(r'^[-–—•*]\s*'), '')
                .trim();
            return Question(text: text, category: category);
          })
          .where((q) => q.text.isNotEmpty)
          .toList();
    } on FirebaseFunctionsException catch (e) {
      throw Exception('[OpenAI] Function error (${e.code}): ${e.message}');
    } catch (e) {
      throw Exception('[OpenAI] Unexpected error: $e');
    }
  }
}
