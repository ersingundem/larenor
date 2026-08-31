class ArrQueueItem {
  const ArrQueueItem({
    required this.id,
    required this.title,
    required this.status,
    this.progressFraction,
    this.timeLeft,
  });

  final int id;
  final String title;
  final String status;
  final double? progressFraction;
  final String? timeLeft;

  factory ArrQueueItem.fromJson(Map<String, dynamic> json) {
    final size = (json['size'] as num?)?.toDouble();
    final sizeLeft = (json['sizeleft'] as num?)?.toDouble();
    double? progress;
    if (size != null && size > 0 && sizeLeft != null) {
      progress = ((size - sizeLeft) / size).clamp(0.0, 1.0);
    }

    final nestedTitle =
        (json['series'] as Map<String, dynamic>?)?['title'] as String? ??
        (json['movie'] as Map<String, dynamic>?)?['title'] as String?;

    return ArrQueueItem(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String? ?? nestedTitle ?? 'Unknown',
      status: json['status'] as String? ?? 'unknown',
      progressFraction: progress,
      timeLeft: json['timeleft'] as String?,
    );
  }
}
