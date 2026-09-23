/// Describes how a Core media view obtained its currently rendered value.
///
/// A verified cache value is still preceded by a fresh Core authority read;
/// it never grants offline command authority or a direct-provider fallback.
enum ServerMediaResultOrigin { live, verifiedCache }
