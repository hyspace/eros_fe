import 'package:eros_fe/models/gallery_image.dart';
import 'package:eros_fe/network/image_endpoint_recovery.dart';

/// Exactly one source change for a preload operation, with the same cache-first
/// loader on both attempts. A failure remains a failure, not a false cache hit.
Future<GalleryImage> preloadWithSourceRecovery(
  GalleryImage image, {
  required Future<void> Function(GalleryImage) load,
  required Future<GalleryImage> Function(GalleryImage) changeSource,
}) async {
  try {
    await load(image);
    return image;
  } catch (error) {
    if (!imageEndpointRecovery.needsNewSource(error) ||
        (image.href?.isEmpty ?? true) ||
        (image.sourceId?.isEmpty ?? true)) {
      rethrow;
    }
    final updated = await changeSource(image);
    await load(updated);
    return updated;
  }
}
