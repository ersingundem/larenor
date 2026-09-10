# S06.5 — Sonarr/Radarr private installation IPC

Bu dilim, Sonarr/Radarr owned configuration runtime'ını Larenor'un UID-korumalı
mutating installation Unix socket'ine bağlar. API key yalnız strict private
model ve bounded IPC paketi içinde kalır; public durum, hata ve makbuz yalnız
sabit kimlikler ile configuration özetini taşır.

## Uçtan uca kapalı sözleşme

- `PrivateArrConfiguration` sadece şema 1, `sonarr`/`radarr` servis kimliği ve
  exact 32 küçük harfli hex API key kabul eder. Fazla alan, gevşek tip, farklı
  servis veya anahtar biçimi reddedilir; `repr` sırrı göstermez.
- Client 32 hex iş kimliği, doğrulanmış `MediaStackPlan`, en fazla 120 saniyelik
  son tarih ve çağrılabilir yetki kapısı olmadan Unix socket'e bağlanmaz.
  Worker peer UID'si eşleşmeli ve istek/yanıt request ID'si aynı olmalıdır.
- Server planı packaged katalogla ve private modeli strict JSON üzerinden tekrar
  doğrular. Yalnız `configure_arr` operasyonu, servis, API key ve yeni iptal
  olayıyla installation runtime'a ulaşabilir.
- Supervisor yolu aynı retained daemon/native thread kanıtını kullanır. Caller
  yetkisi socket çağrısından önce ve sonuçtan sonra tekrar sınanır; sonradan
  yetki kaybı belirsiz etki olur.
- Makbuz exact sınıf ve alan kümesiyle geri kurulur. Sonarr isteğine Radarr
  makbuzu, yabancı dict, özel çıktı veya bilinmeyen worker hatası başarı olamaz.
  Hatalar yalnız sabit kaynak/yazma/sonuç/yetki/timeout kodlarına çevrilir.
- Worker status artık Jellyfin ve qBittorrent yanında Sonarr/Radarr desteğini de
  bildirir; `installAvailable=false` değişmez.

## Kanıt ve açık iş

- Exact kaynak `ebf98c0ff4b9ac31d3057d1471e25bab6d9be242`.
- **18 yeni IPC testi**; Arr runtime, iki IPC paketi, installation runtime ve
  supervisor ile **140 PASS / 1 mevcut macOS skip**.
- Gerçek yerel Unix socket roundtrip, iki servis, peer/status biçimi, ön/son
  yetki kaybı, strict model copy, çapraz servis, bozuk makbuz ve kapalı hata
  projeksiyonu doğrulandı.
- `compileall`, güvenlik politikası, kuyruk, diff ve Gitleaks PASS.

Bu dilim public HTTP endpoint veya kalıcı Core işi eklemez. Sıradaki adım API
key'i bağlamlı AES-GCM kayıt içinde tutan no-retry işi, admin listeleme/iptal ve
otomatik dispatcher'dır. Config başarısından sonra container create/start ve
authenticated API readback ayrıca bağlanacaktır. S06.5 ve
`installAvailable=false` açık kalır.
