import 'package:cura/features/pdf_import/pdf_import_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PDF import progress produces page-specific user copy', () {
    expect(
      const PdfImportProgress(
        PdfImportStage.rendering,
        current: 3,
        total: 8,
      ).label,
      'Rendering page 3 of 8…',
    );
    expect(
      const PdfImportProgress(
        PdfImportStage.reading,
        current: 4,
        total: 8,
      ).label,
      'Reading page 4 of 8…',
    );
  });

  test('PDF import page limit stays aligned with camera scanning', () {
    expect(kPdfImportPageLimit, 20);
  });
}
