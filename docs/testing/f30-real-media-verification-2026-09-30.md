# F30 gerçek medya çıktı doğrulaması

`MediaArchiveOutputVerifier`, host yolu yerine açık dosya descriptor'ını FFmpeg
ve ffprobe'a geçirir. Shell çalıştırmaz; ağ protokolleri ve playlist demuxer'ları
kapalıdır. İşlem, süre/çıktı sınırı ve iptalde sonlandırılır; sağlayıcı logları
public hata cevabına taşınmaz.

Kurulum için yalnız hedef codec doğruluğu yeterli değildir. Kaynak ve çıktı
aynı container, süre, görüntü ölçüleri/pixel formatı ve renk bilgilerini
korumalıdır. Ses/altyazı paket hashleri ve diğer stream bilgileri eşleşir.
Kaynak ve çıktı baştan sona decode edilir; video kare sayısı eşit olmalı ve
çıktı kısalmamalıdır. Tam dosya SHA-256 ve byte uzunluğu daha sonra file-store
install intent'ine bağlanır. Dosya/inode değişirse doğrulama reddedilir.

Dayanak: [ffprobe stream/format ve JSON çıktısı](https://ffmpeg.org/ffprobe.html),
[FFmpeg stream seçimi, decode, progress ve hata seçenekleri](https://ffmpeg.org/ffmpeg.html),
[streamhash muxer](https://ffmpeg.org/ffmpeg-formats.html#streamhash).
Bu kontroller görsel kalite değerlendirmesi veya tüm Client cihazlarında
oynatım kabulünün yerine geçmez.

## Yerel kabul kanıtı

- FFmpeg ve ffprobe `9.0.2`; gerçek iki saniyelik H.264 video, AAC ses ve SRT
  altyazı üretildi, HEVC'ye dönüştürüldü. Kaynak ve çıktılar yalnız test
  dizinindedir; gerçek ev cihazlarına veya medya kitaplığına yazılmadı.
- `server/.venv/bin/python -m pytest -q server/tests/test_media_archive_verifier.py`
  sonucu **9 passed**.
- Daha küçük, ses/altyazı korunmuş HEVC kabul edilir. Eksik ses, farklı ses
  paketleri, yanlış codec, farklı görüntü boyutu, kayıp video kareleri ve kesik
  çıktı reddedilir. İptal/deadline ve symlink/aynı dosya denemeleri güvenle kapanır.
- FFmpeg bağımlılığı yoksa bu fixture testleri skip olur; CI/worker paketinin
  bağımlılığı sağlaması ve bu testleri gerçekten çalıştırması kapanış kapısıdır.
- F30 action runtime, callback outbox ve normal deploy henüz bu kayıtta
  tamamlanmış sayılmaz. F30 kuyruğu açık kalır.
