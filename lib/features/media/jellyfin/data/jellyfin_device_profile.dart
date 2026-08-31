/// Declares what `media_kit` (libmpv) can decode natively, so Jellyfin's
/// PlaybackInfo negotiation picks Direct Play/Direct Stream instead of
/// falling back to server-side transcoding wherever possible — libmpv
/// supports a much broader codec/container set than a typical mobile
/// player, so this profile is intentionally generous.
Map<String, dynamic> buildJellyfinDeviceProfile() {
  return {
    'Name': 'Oikos',
    'MaxStreamingBitrate': 120000000,
    'DirectPlayProfiles': [
      {
        'Container': 'mp4,m4v,mov,mkv,avi,webm,ts,m2ts,flv,wmv',
        'Type': 'Video',
        'VideoCodec': 'h264,hevc,vp8,vp9,av1,mpeg2video,mpeg4,vc1',
        'AudioCodec':
            'aac,mp3,mp2,ac3,eac3,dts,truehd,flac,opus,vorbis,pcm_s16le',
      },
      {'Container': 'mp3,aac,flac,m4a,ogg,wav,wma', 'Type': 'Audio'},
    ],
    'TranscodingProfiles': [
      {
        'Container': 'ts',
        'Type': 'Video',
        'VideoCodec': 'h264',
        'AudioCodec': 'aac',
        'Context': 'Streaming',
        'Protocol': 'hls',
        'MinSegments': 1,
        'BreakOnNonKeyFrames': true,
      },
      {
        'Container': 'mp3',
        'Type': 'Audio',
        'AudioCodec': 'mp3',
        'Context': 'Streaming',
        'Protocol': 'http',
      },
    ],
    'CodecProfiles': <dynamic>[],
    'SubtitleProfiles': [
      {'Format': 'srt', 'Method': 'External'},
      {'Format': 'vtt', 'Method': 'External'},
      {'Format': 'ass', 'Method': 'External'},
      {'Format': 'ssa', 'Method': 'External'},
    ],
  };
}
