import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pinned measure keys (stable; not lab labels).
const kPinnedTrendsKey = 'cura_trend_pins';

Future<Set<String>> pinnedTrends() async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getStringList(kPinnedTrendsKey) ?? const []).toSet();
}

Future<void> setTrendPinned(String key, bool pinned) async {
  final prefs = await SharedPreferences.getInstance();
  final keys = (prefs.getStringList(kPinnedTrendsKey) ?? const []).toSet();
  if (pinned) {
    keys.add(key);
  } else {
    keys.remove(key);
  }
  await prefs.setStringList(kPinnedTrendsKey, keys.toList());
}

/// Refresh card + dashboard after pin changes.
final pinnedTrendsProvider = FutureProvider<Set<String>>((ref) => pinnedTrends());
