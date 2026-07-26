/// Vocabulary used only to score cloud-bound clinical prose. Not an
/// authorization list: unknown words do not disappear from Findings text, and a
/// high unknown-token ratio is just a content-free privacy signal.
///
/// [isKnownClinicalToken] is backed by this hand-curated set plus the generated
/// [kGeneratedClinicalVocabulary] (ICD-10-CM + RxNorm, built by
/// `tool/generate_clinical_vocabulary.dart`). Person and place names are pruned
/// from the generated set, so a name never becomes "known".
library;

import 'clinical_vocabulary.g.dart';

const kClinicalVocabularyVersion = 2;

const kClinicalVocabulary = <String>{
  // Closed-class English and report grammar.
  'a', 'an', 'and', 'any', 'are', 'as', 'at', 'be', 'been', 'being', 'but',
  'by', 'can', 'compared', 'demonstrates', 'did', 'does', 'evidence', 'for',
  'from', 'has', 'have', 'having', 'in', 'is', 'it', 'may', 'most', 'no',
  'not', 'of', 'on', 'or', 'seen', 'shows', 'suggestive', 'than', 'that',
  'the', 'there', 'these', 'this', 'to', 'was', 'were', 'with', 'without',
  'within',

  // Clinical sections, qualifiers, common radiology verbs/adjectives.
  'advice', 'appears', 'approximately', 'assessment', 'borderline', 'clinical',
  'comment', 'comments', 'comparison', 'conclusion', 'condition', 'consistent',
  'detected', 'diagnosis', 'diffuse', 'discharge', 'enlarged', 'examination',
  'finding', 'findings', 'focal', 'history', 'hospital', 'identified',
  'impression', 'increased', 'indication', 'intact', 'mild', 'moderate',
  'morphology', 'negative', 'normal', 'observation', 'opinion', 'positive',
  'present', 'procedure', 'prominent', 'report', 'result', 'results', 'severe',
  'significant', 'stable', 'status', 'study', 'technique', 'treatment',
  'unremarkable', 'visualized',

  // Modalities, anatomy, common findings and lab language.
  'abdomen', 'abdominal', 'artery', 'bladder', 'blood', 'brain', 'breast',
  'cervical', 'chest', 'contrast', 'ct', 'cyst', 'doppler', 'echo', 'ecg',
  'fdg', 'gallbladder', 'gland', 'haemoglobin', 'hemoglobin', 'kidney',
  'kidneys', 'lesion', 'lesions', 'left', 'liver', 'lung', 'lungs', 'lymph',
  'mass', 'mediastinum', 'mri', 'neck', 'node', 'nodes', 'organ', 'pancreas',
  'pelvis', 'pet', 'platelet', 'prostate', 'range', 'reactive', 'region',
  'right', 'scan', 'specimen', 'supraclavicular', 'test', 'thyroid', 'tissue',
  'ultrasound', 'uptake', 'urine', 'value', 'values', 'xray',

  // Units and qualitative table vocabulary.
  'absent', 'cells', 'cmm', 'cumm', 'dl', 'fl', 'g', 'high', 'hpf', 'iu',
  'kg', 'low', 'lpf', 'mcg', 'mg', 'ml', 'mm', 'mmol', 'ng', 'nmol', 'pg',
  'ratio', 'reference', 'sec', 'sensitive', 'unit', 'units',
};

/// Anatomy terms that enrich canonical imaging titles ("Ultrasound — abdomen").
/// Hand-curated so the title builder never emits a place as a region.
const kAnatomyTerms = <String>{
  'abdomen', 'abdominal', 'ankle', 'aorta', 'appendix', 'artery', 'axilla',
  'axillary', 'bladder', 'bone', 'bowel', 'brain', 'breast', 'bronchus',
  'calf', 'cardiac', 'carotid', 'cerebral', 'cervical', 'cervix', 'chest',
  'clavicle', 'colon', 'cranial', 'duodenum', 'elbow', 'esophagus', 'femur',
  'foot', 'forearm', 'gallbladder', 'gland', 'groin', 'hand', 'head', 'heart',
  'hepatic', 'hip', 'humerus', 'ileum', 'intestine', 'jaw', 'joint', 'kidney',
  'kidneys', 'knee', 'larynx', 'leg', 'liver', 'lumbar', 'lung', 'lungs',
  'lymph', 'mediastinum', 'nasal', 'neck', 'nerve', 'orbit', 'ovary', 'pancreas',
  'parotid', 'pelvic', 'pelvis', 'perineum', 'pharynx', 'pleura', 'prostate',
  'pulmonary', 'rectum', 'renal', 'rib', 'sacrum', 'scalp', 'scapula',
  'scrotum', 'shoulder', 'sinus', 'skull', 'spine', 'spleen', 'sternum',
  'stomach', 'supraclavicular', 'testis', 'thigh', 'thoracic', 'thorax',
  'thyroid', 'tibia', 'trachea', 'ureter', 'urethra', 'uterus', 'vertebra',
  'wrist',
};

bool isKnownClinicalToken(String token) {
  final t = token.toLowerCase();
  return kClinicalVocabulary.contains(t) ||
      kAnatomyTerms.contains(t) ||
      kGeneratedClinicalVocabulary.contains(t);
}
