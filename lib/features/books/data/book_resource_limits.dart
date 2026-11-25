/// Raw payload limits; persistent budgets count the encoded database bytes.
abstract final class BookResourceLimits {
  static const imageBytes = 4 * 1024 * 1024;
  static const chapterImageBytes = 48 * 1024 * 1024;
  static const chapterImages = 100;
  static const readingBytes = 24 * 1024 * 1024;
  static const offlineTextBytes = 384 * 1024 * 1024;
  static const privateVaultBytes = 192 * 1024 * 1024;
  static const offlineImageBytes = 192 * 1024 * 1024;
}
