# qBittorrent config worker etkisi — uygulama ve açık kabul sınırı

**Tarih:** 10 Eylül 2026
**Kuyruk:** S06.5 — özel bootstrap ve otomatik servis eşleştirme

## Tamamlanan private worker zinciri

Larenor Server, journal'a bağlı sahipli qBittorrent config'ini disposable
yardımcı container'a özel stdin üzerinden gönderecek kapalı Engine taşıyıcısını
ve effect koordinatörünü kazandı. Taşıyıcı Docker API 1.47 uyumluluğunu, Unix
socket ancestry/kimliğini ve peer UID'yi aynı bağlantıda doğruladıktan sonra
yalnız üretilmiş 64 haneli container kimliğinin attach kanalını açıyor.

Config en fazla 4096 byte olabilir ve container create JSON'una, label'a,
ortam değişkenine veya komut satırına girmez. Attach isteği sabit
`stream/stdin/stdout/stderr` alanlarına sahiptir; TTY ve websocket yoktur.
Yetki kapısı attach öncesinde ve private byte gönderiminden hemen önce yeniden
çalışır. Çıktı Docker'ın non-TTY multiplex frame biçiminde, toplam byte, frame,
idle ve total süre sınırlarıyla ayrıştırılır.

Effect, tek sabit helper imajını aşağıdaki sınırlarla çalıştırır:

- ağ tamamen kapalı, root filesystem salt okunur ve tüm capability'ler düşürülmüş;
- kullanıcı `1000:1000`, process ve bellek sınırları sabit;
- yalnız journal-bound qBittorrent appdata volume `/volume` hedefine yazılabilir;
- komut yalnız `install_qbittorrent_config`;
- create → start → private stdin → exact helper sonucu → wait → remove sırası;
- config digest/state sonucu exact geri okunur, kaynak ve yetki etkiden sonra
  tekrar doğrulanır;
- retry yoktur; stream, sonuç, wait ve cleanup belirsizliği secret-free kodla
  korunur.

## Doğrulama

- Engine stdin sürüm/upgrade/frame/sınır/iptal/yetki testleri: 21.
- Journal bağı, sabit container gövdesi, lifecycle, cleanup ve sahte kaynak
  testleri: 16.
- Mevcut Engine HTTP, volume helper/runtime ve config binding paketleriyle
  birlikte 274 ilgili test geçti.
- Değişen Python kaynakları compileall ve diff kontrolünden geçti; sır taraması
  teslim kapısında yeniden çalıştırılacak.

## Açık kabul kapıları

- Yeni effect henüz installation supervisor/IPC job state zincirinden çağrılmıyor.
- qBittorrent managed container planı effect receipt olmadan start edilemez hale
  henüz getirilmedi.
- Helper ve gerçek qBittorrent 5.2.3 üzerinde AMD64/ARM64 native config/API
  geri okuması tamamlanmadı.
- Bu kapılar tamamlanana kadar `installAvailable=false` ve S06.5 sayacı korunur.

Sonraki dilim effect'i retained daemon lease ve kalıcı journal state geçişine
bağlayacak; ardından aynı config özeti container içinden authenticated API ile
yeniden doğrulanacak.
