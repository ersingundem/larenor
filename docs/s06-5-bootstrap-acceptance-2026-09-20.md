# S06.5 özel bootstrap kabulü

**Kabul edilen kaynak:** `f78f138c76fb1605bfdc18473d545ecf49689eef`
**Ana dal eşdeğeri:** `b38c8ab9cc7b73e20f2e3399c8111a2453f150f9`
**Karar tarihi:** 20 Eylül 2026

S06.5'in yazılım kapsamı aşağıdaki üç ölçütle kapandı. PR kaynağının ve squash
merge'in Git ağaç kimliği aynıdır:
`7afb4232d6328fca088833b11759f4e16512688d`. Bu nedenle native makbuzların
çalıştığı exact kaynak, güncel `main` içeriğiyle byte düzeyinde aynıdır.

## Son üç kabul ölçütü

1. **Özel kimlik ve ilk kullanıcı zinciri.** Jellyfin, qBittorrent,
   Sonarr/Radarr, Seerr ve Music Assistant için kimlikler Larenor tarafından
   üretilir; kalıcı niyet ve sonuçlar şifreli tutulur. İlk kullanıcı ve servis
   bootstrap'ı UID denetimli Unix IPC ile, journal'dan yeniden türetilen özel
   endpointlerde çalışır. Client, plan, makbuz ve hata projeksiyonları parola,
   cookie veya API anahtarı taşımaz.
2. **Otomatik eşleştirme, geri okuma ve kısmi sonuç.** qBittorrent kategorileri,
   Arr indirme istemcisi ve kök klasörleri, Seerr'ın Jellyfin/Arr ayarları ile
   initialize durumu ve Music Assistant'ın yönetici, provider, player ve
   playback yolları authenticated readback ile doğrulanır. Restart aynı kimliği
   korur; eksik, belirsiz veya çakışan adım başarıya yükseltilmez ve kör yeniden
   yürütülmez.
3. **Sabit sürüm ve iki mimarili gerçek süreç kanıtı.** Seerr 3.4.1 ve Music
   Assistant 2.10.4 exact-source allowlist ile gerçek amd64/arm64
   konteynerlerinde fresh-state, restart ve secret-free receipt kapılarından
   geçti. Aynı exact kaynakta Android/Server/Security kabulü de yeşildir.

## Uzak kanıt

- [Seerr native karakterizasyonu](https://github.com/ersingundem/larenor/actions/runs/35520684986):
  exact `f78f138c`, amd64 ve arm64 geçti.
- [Music Assistant native karakterizasyonu](https://github.com/ersingundem/larenor/actions/runs/35520685005):
  exact `f78f138c`, amd64 ve arm64 geçti.
- [Ortak Android/Server kabulü](https://github.com/ersingundem/larenor/actions/runs/35520685138):
  exact `f78f138c`; analiz, dört Flutter shardı, dört Server shardı, debug APK ve
  API 35 yolculukları geçti.
- [Ana dal Security](https://github.com/ersingundem/larenor/actions/runs/35521463120):
  exact `b38c8ab9` geçti.
- [Ana dal Server Container](https://github.com/ersingundem/larenor/actions/runs/35521463270):
  exact `b38c8ab9`; dört Server shardı, amd64/arm64 build/smoke ve immutable
  manifest kapıları geçti.

Yerel kapanış kontrolünde 52 Seerr/Music Assistant runtime testi ve 53
kuyruk/ilerleme/native-workflow araç testi geçti. `execution_queue.py validate`,
`git diff --check` ve `commit_with_progress.py --dry-run` sırasıyla 125 işi,
**16/125 (%12,8)** kuyruğu ve **0/63** özellik kabulünü doğruladı.

## Korunan sınır

Bu kabul disposable CI daemon'larında yazılım bootstrap sözleşmesini kanıtlar.
CasaOS/Proxmox kurulumu, gerçek Spotify/Apple Music/YouTube Music hesabı ve
HomePod/Cast cihazı `S07` ile `MANUAL` kapılarında kalır. S06.5'in kapanması
`installAvailable` değerini açmaz, birleşik tek-kurulum paketini tamamlanmış
saymaz ve fiziksel cihaz kabulü yerine geçmez. Sıradaki yazılım işi S06.6'nın
doğrulanmış sonuç, iptal ve kurtarma zinciridir.
