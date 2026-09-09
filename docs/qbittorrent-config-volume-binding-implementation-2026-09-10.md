# qBittorrent config–volume bağı — uygulama ve açık kabul sınırı

**Tarih:** 10 Eylül 2026  
**Kuyruk:** S06.5 — özel bootstrap ve otomatik servis eşleştirme

## Tamamlanan kapalı Core sözleşmesi

`QbittorrentConfigBinding`, sahipli qBittorrent config bytes değerini doğrudan
bir istemci yolu veya volume adına göre üretmiyor. Kaynak önce güncel
`VolumeCreateJournal` içinden aynı revision ile yeniden okunuyor ve tam media
stack, catalog, worker policy ve volume planı yeniden türetiliyor.

Kabul için aşağıdaki bağların tamamı gerekiyor:

- kaynak `qbittorrent` servisinin `managed_appdata` türündeki `/config`
  hacmi olmalı;
- journal state `observed_requires_bootstrap`, revision en az 3 olmalı;
- resource, operation, preparation, plan ve worker policy özetleri eşleşmeli;
- journal kimliği, ownership nonce, volume adı ve resource specification özeti
  güncel kayıtla aynı olmalı;
- child planın appdata kökü, relative path'i ve qBittorrent portları yeniden
  türetilmeli;
- çıktı config özetiyle ve gömülü PBKDF2 salt ile tekrar doğrulanabilmeli.

Sonuç yalnız worker belleğinde config bytes taşır; `repr` parola, Bearer anahtarı,
PBKDF2 kaydı veya config içeriği göstermez. Bu adım journal'da state değişikliği
yapmaz, socket açmaz ve subprocess başlatmaz.

`SharedLibraryConsumerPlan` aynı mevcut yönetilen library volume kaynağını
dört sabit tüketiciyle ilişkilendirir: qBittorrent, Sonarr ve Radarr `/data`
üzerinde yazılabilir; Jellyfin `/media` üzerinde salt okunurdur. Her tüketicinin
installation ID, child plan hash, container user, root ID ve catalog mount'u
yeniden türetilir. Seerr ve Music Assistant bu volume'e eklenmez. Plan
`installAvailable=false` ve `bindingStatus=proposed` sınırlarını korur.

## Doğrulama

- 15 yeni config–volume bağlama ve sahte kaynak reddi testi geçti.
- 19 yeni ortak library tüketici planı testi geçti.
- qBittorrent, volume plan/resource/journal paketleriyle 315 ilgili test geçti.
- Değişen Python modülleri `compileall`, diff kontrolü ve gitleaks taramasından
  geçti.

## Açık kabul kapıları

- Config henüz geçici helper üzerinden appdata hacmine atomik yazılmıyor.
- Yazma öncesi ve sonrası aynı journal/daemon/volume lease'i tutulmuyor.
- Ortak medya hacmi tüketicileri planlandı; bu plan henüz taze typed volume
  proof ve container binding içinde zorunlu tutulmuyor.
- qBittorrent managed container create/start, endpoint proof ve amd64/arm64
  gerçek API geri okuması bağlı değil.
- `installAvailable=false` ve S06.5 kuyruk sayacı korunuyor.

Bir sonraki adım config write effect'ini journal öncesi/sonrası yeniden bağlayıp
ardından aynı kaynağı pinned iki mimarili container kabuline taşımaktır.
