// Round-trips the source-ref packing that lets a multi-report count persist its
// cited cards in the single `sourceDocId` text column (no schema migration).

import 'package:flutter_test/flutter_test.dart';

import 'package:cura/features/ask/chat_models.dart';
import 'package:cura/features/library/document.dart';

CuraDocument _doc(String id) => CuraDocument(
  id: id,
  title: id,
  type: DocumentType.lab,
  date: DateTime(2024, 1, 1),
);

void main() {
  group('encodeSourceRef', () {
    test('nothing to cite → null', () {
      expect(encodeSourceRef(const [], 0), isNull);
    });

    test('single source → bare id (byte-identical to legacy rows)', () {
      expect(encodeSourceRef([_doc('cbc')], 1), 'cbc');
    });

    test('multi source → ids joined with the true total', () {
      expect(encodeSourceRef([_doc('a'), _doc('b')], 5), 'a,b#5');
    });
  });

  group('decodeSourceRef', () {
    test('legacy single id → one id, total 1', () {
      final r = decodeSourceRef('cbc');
      expect(r.ids, ['cbc']);
      expect(r.total, 1);
    });

    test('packed multi → ids and true total', () {
      final r = decodeSourceRef('a,b#5');
      expect(r.ids, ['a', 'b']);
      expect(r.total, 5);
    });

    test('round-trips a complete multi-source ref', () {
      final docs = [for (var i = 0; i < 9; i++) _doc('doc$i')];
      final encoded = encodeSourceRef(docs, docs.length)!;
      final r = decodeSourceRef(encoded);
      expect(r.ids, [for (var i = 0; i < 9; i++) 'doc$i']);
      expect(r.total, 9);
    });

    test('malformed total falls back to the id count', () {
      final r = decodeSourceRef('a,b#');
      expect(r.ids, ['a', 'b']);
      expect(r.total, 2);
    });
  });
}
