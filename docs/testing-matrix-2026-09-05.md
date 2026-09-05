# Test kapsamı ve cihaz doğrulama matrisi

Bu matris 5 Eylül 2026 tarihindeki gerçek test dosyalarını eşler. Bir satırda test bulunması o özelliğin bütün sunucu sürümlerinde veya fiziksel cihazlarda doğrulandığı anlamına gelmez. Test adedi ve satır kapsamı bir ürünün “%100 çalıştığı” iddiası için kullanılmaz.

## CI kapıları

- [Analyze & Test](../.github/workflows/analyze-test.yml): biçim, statik analiz, bütün `test/` unit/widget regresyonları ve LCOV. `test/performance/` altındaki kontroller abonelik/istek ve veri işleme davranışını sınar; cihaz FPS veya pil ölçümü değildir.
- [Android Build](../.github/workflows/android-build.yml): debug APK, Android JVM/Robolectric testleri ve imzalama sınırları. İmzalı APK işi aynı commit'in analiz/widget, native ve E2E işlerini bekler.
- [Android E2E](../.github/workflows/android-e2e.yml): API 35 AOSP x86_64 emülatöründe gerçek uygulama ve Android Flutter renderer. Tekrar kullanılabilir iş olarak Android Build tarafından çağrılır; bağımsız elle de başlatılabilir. Aynı push için ikinci bir otomatik emülatör işi oluşturmaz.
- [Server API & Storage Tests](../.github/workflows/server-test.yml): kilitli Python bağımlılıkları, hesap/rol, şifreli kasa, yönetim, kaynak/lisans ve sürüm yayımlama testleri. Java 17 ve SHA-256 ile sabitlenmiş resmi `apksig 9.1.0` kullanır; gerçek imza testleri araç eksikliği nedeniyle sessizce atlanmaz. Android Build'in imzalı APK işi bu kapıyı da bekler.
- [Security](../.github/workflows/security.yml): sır taraması, bağımlılık taraması, [Python politika testleri](../tool/tests/security_policy_test.py), [imzalama testleri](../tool/tests/android_signing_test.py).

E2E işinde secrets aktarılmaz, checkout kimlik bilgisi bırakılmaz, dış action'lar tam commit SHA ile sabitlenir. Emülatör boot sınırı 5 dakika, test komutu sınırı 18 dakika, iş sınırı 35 dakikadır. Başarısız E2E imzalı APK yayımlamayı engeller. Yalnız sentetik test runner çıktısı 7 gün saklanır; global logcat, uygulama depoları, kasa dosyaları ve sağlık verisi artifact değildir.

Test raporu artifact olarak ayrıca yüklenmeye çalışılır. Kota/servis nedeniyle
yükleme başarısızsa uyarı ve iş özeti yazılır; asıl test adımının sonucu değişmez
ve çıktısı CI iş loglarında kalır. Test adımlarında hata görmezden gelinmez.
İmzalı APK teslimi bu isteğe bağlı rapor yüklemesi kapsamında değildir.

## Gerçek emülatör senaryoları

[app_journeys_test.dart](../integration_test/app_journeys_test.dart) `IntegrationTestWidgetsFlutterBinding` kullanır. [App harness](../integration_test/support/app_harness.dart) gerçek `LarenorApp`, router, PIN doğrulama, backup codec/repository ve `ConfigurationScope` yeniden kurulumunu çalıştırır. Metin girişi Flutter'ın resmi test keyboard kanalıyla sağlanır; gerçek Android IME sınanmaz. Widget'ların `onTap` callback'leri elle çağrılmaz; ekrana dokunma, metin girişi ve geri gezinme kullanılır.

1. Temiz başlangıç → gerçek Connect formunda reddedilen sentetik token → doğru tokenla HTTP/WS bağlantısı → dashboard durumu → Routines ayrıntısı → System/Media/Home dönüşü → yanlış/doğru PIN → Ayarlar'dan çıkış sonrası tekrar kilit.
2. Ayarlar PIN'i → varsayılan olarak credentials içermeyen gerçek şifreli export → iptal edilen dosya seçimi → yanlış parola ile başarısız decrypt → doğru parola ve preview → mevcut veriyi değiştirme seçimi → açık restore onayı → gerçek yerel repository değişimi → bütün provider/router ağacının yeniden kurulması → eski WS bağlantısının kapanması ve yeni auth/abonelik → PIN'in korunması.

3. Global aramada sentetik lambayı bul → gerçek entity kontrolü → HTTP komut kabulü → durum hâlâ eskiyken bekleme makbuzu → ayrı WS state event → gözlenen sonuç; tek kullanıcı eylemine tek komut.
4. PIN → Ekran ve parlaklık → haftalık program editörü → günler/tüm gün/sistem zaman aşımı/karartma tercihi → açık kaydet → yeni uygulama/provider ağacı → PIN ve kayıtlı programın tekrar okunması.

[platform_storage_test.dart](../integration_test/platform_storage_test.dart) dört ayrı senaryoda gerçek FlutterSecureStorage, cache dışından tekrar okunan legacy SharedPreferences, SharedPreferencesAsync ve native kiosk/window salt okunur snapshot sözleşmesini çalıştırır. Yalnız test ad alanı anahtarlarını yazar ve temizler; provider veya native channel taklidi kullanmaz. Bunlar aynı süreçte taze istemciyle native kalıcılık kanıtıdır; process restart, reinstall veya hardware-backed Keystore garantisi değildir.

HA fixture yalnız aynı test sürecinin `127.0.0.1` portunda yaşar; [HTTP/WS sunucusu](../integration_test/support/synthetic_ha_server.dart) yalnız açıkça etkinleştirilen sentetik light.turn_on/turn_off komutlarını kabul eder; diğer yazmaları reddeder ve sayar. Dart HttpClient/WS için beklenmeyen hedefler ve proxy socketleri bağlantı açılmadan engellenir; automatic/manual redirect ve HTTP/CONNECT proxy trap regresyonları vardır. Bu sınır raw Socket, native WebView veya Media3 için süreç çapında firewall iddiası değildir. Harness bağımsız root ProviderContainer'ını gerçek ConfigurationScope restore sınırında dispose eder ve yeniden oluşturur; test overrides böylece generated provider'lara da uygulanır. Her HA WebSocket istemcisi gerçek kanal ve protokol kullanır; yalnız HTTP transport nesnesi mevcut factory seam üzerinden o testin portuna bağlanır. Böylece Dart SDK'nın süreç boyunca tuttuğu varsayılan WebSocket HTTP istemcisi önceki testin portunu yeniden kullanamaz. mDNS taraması kapalıdır. Üretim adresi veya tokenı test konfigürasyonuna alınmaz.

App journey harness içinde Keystore/Keychain ve preferences bellekte tutulur; OS dosya seçicisi yalnız şifreli baytları taşıyan bir test adaptörüdür. Dolayısıyla app journey senaryoları **gerçek OS dosya izinlerini, Android credential şifrelemesini veya harici HA sunucusunu doğrulamaz**. Bunlar aşağıdaki ayrı native/cihaz kapsamlarına aittir.

## Özellik → kanıt

Tablodaki dosyalar temsilî giriş noktalarıdır; aynı klasördeki diğer `_test.dart` dosyaları da CI'da çalışır. “Yok” sonraki otomasyon dilimini belirtir.

| Özellik | Unit / protokol / veri | Widget / kullanıcı akışı | Android native | API 35 E2E | Fiziksel cihaz / harici servis açığı |
|---|---|---|---|---|---|
| HA bağlantı, REST, WS ve hesap değişimi | [REST](../test/features/ha_client/rest_client_test.dart), [WS](../test/features/ha_client/ws_client_test.dart), [hesap kapsamı](../test/features/ha_client/connection_scope_providers_test.dart) | [bağlantı kökleri](../test/features/service_root_screens_test.dart) | — | Reddedilen token, başarılı loopback bağlantı, entity snapshot ve WS aboneliği | Gerçek HA sürüm/rol matrisi, ağ kaybı ve TLS uçları |
| Ana gezinme, arama, odalar | [arama indeksi](../test/features/navigation/search/local_search_index_test.dart), [oda sync](../test/features/dashboard/room_area_sync_test.dart) | [gezinme](../test/features/navigation/app_navigation_test.dart), [editör](../test/features/dashboard/dashboard_edit_ui_test.dart), [masaüstü](../test/features/navigation/desktop_navigation_test.dart) | — | Home/Routines/System/Media, global entity araması ve ayrıntı rotası; oda düzenleme E2E henüz yok | Tablet pencere geçişleri, erişilebilirlik ve gerçek klavye |
| Dashboard kartları ve HA komutları | [layout](../test/features/dashboard/dashboard_repository_test.dart), [komut kabulü](../test/features/health/action_controller_test.dart) | [kontroller](../test/features/dashboard/entity_controls_test.dart), [eski hesap engeli](../test/features/dashboard/ha_entity_session_ui_test.dart), [tile](../test/features/dashboard/legacy_tile_actions_test.dart) | — | Kart gösterimi, gerçek kontrol→HTTP kabulü→ayrı WS durum gözlemi; yalnız sentetik lamba | Ayrı test HA'sında fiziksel durum gözlemi; üretim HA'ya yazılmaz |
| Yerel native depolama | [secure/prefs sözleşmeleri](../integration_test/platform_storage_test.dart) | — | Gerçek eklenti kanalları | SecureStorage, legacy/async preferences yaz→taze oku→sil | Süreç yeniden başlatma, disk-full, hardware-backed nitelik ve iOS |
| PIN ve Ayarlar | [PIN](../test/features/settings/pin_lock_store_test.dart) | [kapı](../test/features/settings/settings_gate_screen_test.dart), [split](../test/features/settings/settings_split_screen_test.dart) | — | Yanlış/doğru PIN, çıkınca yeniden kilit | Gerçek Keychain/Keystore hataları, Android task-switch ekranları |
| Şifreli backup / restore | [codec](../test/features/backup/backup_codec_test.dart), [transaction](../test/features/backup/backup_repository_test.dart), [privacy](../test/features/backup/backup_disclosure_test.dart) | [backup ekranı](../test/features/backup/backup_screen_test.dart), [scope](../test/core/configuration_scope_test.dart) | Android backup-exclusion XML'i Python politikasıyla | Gerçek şifreleme, iptal, yanlış parola, preview, restore, scope reset | OS DocumentsUI/cloud provider, process kill / disk-full / gerçek secure storage |
| Larenor Server hesabı ve şifreli kasa | [Server auth/storage](../server/tests/test_auth.py), [API sınırı](../server/tests/test_api_boundary.py), [Client hesap](../test/features/server/server_account_test.dart), [kasa controller](../test/features/server/server_vault_controller_test.dart) | [hesap](../test/features/server/server_connection_screen_test.dart), [kasa](../test/features/server/server_vault_screen_test.dart), [korumalı giriş](../test/features/server/server_entry_points_test.dart) | Bu dilimde host fixture | Yok | Gerçek sunucu/TLS, fiziksel cihaz depolaması, CasaOS kurulumu ve cihazlar arası taşıma kabulü |
| Larenor Server kullanıcı, oturum ve işlem günlüğü yönetimi | [Server admin](../server/tests/test_admin.py), [migration](../server/tests/test_admin_migration.py), [Client admin controller](../test/features/server/server_admin_controller_test.dart) | [admin UI](../test/features/server/server_admin_screen_test.dart): revision çatışması, son etkin yönetici, geçici parola, iptal/onay, sayfalama ve yaşam döngüsü | — | Yok | Gerçek sunucu rol matrisi, cihaz oturumu kapatma ve erişilebilirlik teknolojileriyle fiziksel kabul |
| Client APK yayımlama ve güncelleme | [staging/atomiklik/kota](../server/tests/test_releases.py), [gerçek APK imzası](../server/tests/test_releases_verifier.py), [publisher](../tool/tests/publish_client_release_test.py), [Client protokol](../test/features/client_updates/client_updates_test.dart) | [güncelleme UI](../test/features/client_updates/client_updates_screen_test.dart): yayımlanmamış sürüm, hata, indir/doğrula/kur ayrımı ve eski hesap engeli | [APK imzası](../android/app/src/test/kotlin/com/ersingundem/larenor/updater/ApkSignatureTest.kt), [köprü](../android/app/src/test/kotlin/com/ersingundem/larenor/updater/ClientUpdaterBridgeTest.kt), [güvenlik](../android/app/src/test/kotlin/com/ersingundem/larenor/updater/UpdateSecurityTest.kt) | Yok | Fiziksel Android installer, bilinmeyen kaynak izni, süreç ölümü ve gerçek yükseltme; bu doğrulamada sürüm yayımlanmadı |
| HA admin, otomasyon, servis formları | [admin API](../test/features/admin/admin_client_test.dart), [şemalar](../test/features/admin/admin_models_test.dart) | [admin flows](../test/features/admin/admin_workflows_test.dart), [actions](../test/features/ha_tools/ha_actions_test.dart) | — | Yok | Yetki ve sunucu sürümü matrisi; yalnız ayrı test ortamında yazma |
| Today / todo / takvim / bildirim | [API](../test/features/today/today_api_test.dart), [actions](../test/features/today/today_actions_test.dart) | [Today](../test/features/today/today_screen_test.dart) | — | Yok | Saat dilimi, izinler ve gerçek entegrasyon verileri |
| Enerji ve bakım | [istatistik](../test/features/energy/energy_statistics_test.dart), [repository](../test/features/energy/energy_repository_test.dart) | [ekran](../test/features/energy/energy_screen_test.dart) | — | Yok | Gerçek meter/utility/recorder yapılandırmaları |
| Kapı istasyonu / kamera | [door release](../test/features/intercom/door_release_test.dart) | [intercom](../test/features/intercom/intercom_screen_test.dart), [kamera](../test/shared/widgets/camera_snapshot_test.dart) | — | Yok | Netelsan/diğer gerçek donanım, ses/video, kapı rölesi; otomatik açma testi yok |
| Medya kataloğu ve indirme aşamaları | [indeks](../test/features/media/hub/media_library_index_test.dart), [ilerleme](../test/features/media/hub/media_progress_test.dart) | [hub](../test/features/media/hub/media_hub_screen_test.dart), [ilerleme UI](../test/features/media/hub/media_progress_ui_test.dart) | — | Medya kökü gezinme smoke'u; katalog yok | Gerçek servis eşleşmesi ve büyük kişisel kütüphaneler |
| Jellyfin / video oynatma | [client](../test/features/media/jellyfin/jellyfin_client_test.dart), [playback güvenliği](../test/features/media/jellyfin/jellyfin_playback_security_test.dart) | [player yaşam döngüsü](../test/features/media/jellyfin/jellyfin_player_lifecycle_test.dart) | — | Yok | Codec, transcode, donanım decode, altyazı ve gerçek ses/video çıkışı |
| Seerr, Sonarr/Radarr/Lidarr/Readarr, Bazarr, Prowlarr | [Seerr](../test/features/media/jellyseerr/jellyseerr_client_test.dart), [Arr](../test/features/media/arr/arr_client_test.dart), [Bazarr](../test/features/media/bazarr/bazarr_client_test.dart), [Prowlarr](../test/features/media/prowlarr/prowlarr_client_test.dart) | [Seerr session](../test/features/media/jellyseerr/jellyseerr_session_ui_test.dart), [Arr ekleme](../test/features/media/arr/arr_add_session_test.dart) | — | Yok | Sürüm/rol ve request→import zinciri; ayrı test sunucuları |
| qBittorrent | [client](../test/features/media/qbittorrent/qbittorrent_client_test.dart), [provider](../test/features/media/qbittorrent/qbittorrent_providers_test.dart) | [qB UI](../test/features/media/qbittorrent/qbittorrent_ui_test.dart) | — | Yok | Gerçek torrent daemon ve DocumentsUI; dosya silme test edilmez |
| HA kaynak oynatma, casting, Music Assistant | [HA playback](../test/features/media/ha_playback/ha_playback_controller_test.dart), [remote](../test/features/media/casting/remote_playback_controller_test.dart), [music](../test/features/media/music/music_playback_test.dart) | [HA UI](../test/features/media/ha_playback/ha_playback_ui_test.dart), [music UI](../test/features/media/music/music_ui_test.dart) | — | Yok | Cast/Apple TV/HomePod erişilebilirlik, codec, HA/MA izinleri; kabul ≠ fiziksel oynatma |
| Movie Night | [runner](../test/features/media/movie_night/movie_night_runner_test.dart) | [launcher](../test/features/media/movie_night/movie_night_launcher_test.dart) | — | Yok | Gerçek sahne ve cihaz oynatımı; bitiş sahnesi daima kullanıcı eylemi |
| Yerel ses ve albüm kapağı | [Dart köprüsü](../test/features/media/local_audio/local_audio_bridge_test.dart), [artwork okuma](../test/features/media/local_audio/local_audio_artwork_review_test.dart) | [ses UI](../test/features/media/local_audio/local_audio_ui_test.dart), [kapak UI](../test/features/media/local_audio/local_audio_artwork_ui_test.dart) | [MediaSession](../android/app/src/test/kotlin/com/ersingundem/larenor/audio/LocalAudioServiceTest.kt), [metadata sınırı](../android/app/src/test/kotlin/com/ersingundem/larenor/audio/AudioArtworkMetadataReviewTest.kt), [decoder](../android/app/src/test/kotlin/com/ersingundem/larenor/audio/AudioArtworkTest.kt) | Yok | Kilit ekranı/Bluetooth kulaklık/gerçek audio focus, provider seçicisi ve codec |
| Proxmox | [client](../test/features/proxmox/proxmox_client_test.dart), [transport](../test/features/proxmox/proxmox_transport_security_test.dart) | [mutation güvenliği](../test/features/proxmox/proxmox_mutation_ui_test.dart), [console session](../test/features/proxmox/proxmox_session_ui_test.dart) | — | Yok | Gerçek VM/LXC console, yetki, self-signed sertifika, task terminal sonucu |
| Keenetic | [client](../test/features/keenetic/keenetic_client_test.dart), [telemetry](../test/features/keenetic/keenetic_telemetry_test.dart) | [ekranlar](../test/features/keenetic/keenetic_screens_test.dart), [metrikler](../test/features/keenetic/keenetic_metric_ui_test.dart) | — | Yok | KeeneticOS sürüm/cihaz API farkları ve gerçek ağ |
| Web panelleri | [origin policy](../test/features/web_panel/web_panel_policy_test.dart), [oturum temizliği](../test/features/web_panel/web_panel_data_test.dart) | [settings](../test/features/web_panel/web_panel_settings_test.dart), [view](../test/features/web_panel/web_panel_view_test.dart) | — | Yok | Gerçek Chromium/WKWebView, OAuth, pop-up, cookie/IndexedDB ve renderer recovery |
| Ambient / ekran programı / idle | [repo IO](../test/features/ambient/ambient_repository_review_test.dart), [program](../test/features/settings/screen_program_test.dart) | [ambient](../test/features/ambient/ambient_ui_test.dart), [idle](../test/features/settings/idle_gate_test.dart), [program UI](../test/features/settings/screen_program_ui_test.dart) | Pencere alt satırda | Program editöründe kaydet ve yeni uygulama kapsamında tekrar oku | Saat/güneş/batarya, yerel video, uyku/uyanma ve uzun süreli panel |
| Pencere ve kiosk | [window](../test/core/window/window_policy_test.dart), [kiosk](../test/features/kiosk/kiosk_controller_test.dart) | [window](../test/features/settings/window_panel_screen_test.dart), [kiosk](../test/features/kiosk/kiosk_screen_test.dart) | [window](../android/app/src/test/kotlin/com/ersingundem/larenor/window/WindowPolicyBridgeTest.kt), [kiosk](../android/app/src/test/kotlin/com/ersingundem/larenor/kiosk/KioskBridgeTest.kt) | Gerçek window/kiosk snapshot: unmanaged, foreground; DPC/pinning yok | Device Owner provisioning, fiziksel pinning çıkışı, HarmonyOS pencere yönetimi |
| Kişisel sağlık / özel HA ölçümleri | [veri](../test/features/wellbeing/wellbeing_data_test.dart), [privacy](../test/features/wellbeing/wellbeing_privacy_test.dart) | [gated UI](../test/features/wellbeing/wellbeing_screen_test.dart) | [reader](../android/app/src/test/kotlin/com/ersingundem/larenor/wellbeing/WellbeingReaderTest.kt), [secure view](../android/app/src/test/kotlin/com/ersingundem/larenor/wellbeing/WellbeingPrivateViewTest.kt) | Yok | Gerçek Health Connect izinleri/uyumluluğu; Huawei/GMS'siz durum, HealthKit ayrı platform işi |

## Doğrulanan yerel koşum

**S05 son yayın kontrolü (5 Eylül, 13:49 TRT):** **2.333 Flutter**, **529 Server**
ve **114 Python araç/politika testi** geçti. Tam analiz ve 747 Dart dosyasının
biçim kontrolü temiz. Server koşumu yalnız geliştirilmekte olan S06 katalog test
dosyasını dışarıda bırakır; o dosya S05 yayın paketine dahil değildir. Yeni
Keenetic açık oturum çerezi ve Client kimlik bilgisi alanları bu son koşumlarda
yer alır. Ortak [JSON sözleşmesi](../contracts/service-connections.v1.json)
aynı yaşam döngüsünü hem gerçek FastAPI route'ları hem Dart Client üzerinden
doğrular. Önceki alt paket adetleri bu toplamlara tekrar eklenmez.

**S05 bütünleştirme kontrolü (5 Eylül, 13:32 TRT):** Yeni hizmet yönetimi dahil
**2.327 Flutter testi** geçti; tam analiz temiz. **106 Python araç/politika
testi** geçti. Server bağlantı kayıtları 63 test; HTTP taşıması, bağımsız
incelemenin iki düzeltmesiyle 87 test; admin kontrol API'si ve gerçek yerel HTTP
akışı 17 test geçti. Servis adaptörleri genişletiliyor; bu ara sayılar son birleşik
Server koşumunun yerine geçmez. Yeni Client alanları önceki 98 native testi
değiştirmedi; gerçek CI/emülatör sonucu ayrıca izlenir.

S05 kanıt dosyaları ve sınırları
[merkezi hizmet bağlantıları](server-service-connections.md#test-kanıtı-ve-sınırlar)
belgesindedir. Yeni `server/tests/` ve `test/` dosyaları mevcut CI keşfine dahildir.
Kontrol sırasında revizyon/rol/oturum değişimi, secret redaksiyonu, TLS/DNS,
boyut/süre sınırları ve tablet klavyesi ayrı regresyonlarla kapsanır.

**Son birleşik yerel kontrol (5 Eylül, 12:45 TRT):** 2.297 Flutter testi,
18 pakette 98 Android native testi, 154 Server testi ve 97 Python araç/politika
testi geçti. Tam Flutter analizi, workflow actionlint kontrolü ve yayımlanabilir
dosyaların sır taraması temizdir. Aşağıdaki alt paket sayıları bu sonuçlara yeniden
eklenmez. GitHub CI, Docker'ın gerçek çalışması ve fiziksel kabul ayrı izlenir.

Otomatik güncelleme uyarısının [21 widget testi](../test/features/client_updates/client_update_notice_test.dart)
ön plan kontrolü, kapatma/yeni sürüm, imza/sürüm/SDK sınırı, hesap/rota/PIN/idle
geçişleri ve dar ekran davranışını kapsar. İlgili güncelleme/gezinme paketi 92/92
geçti; bu testler tam Flutter paketinin içindedir. [Server container politika testleri](../tool/tests/server_container_policy_test.py)
yalnız çevrimdışı imaj/yayın sınırlarını doğrular; 13 test, 97 araç testinin içindedir.
Ek dört [tarama sınırı testi](../tool/tests/security_scan_policy_test.py) OSV bulgu,
API/yapılandırma/boş paket ve container hata kodlarının CI'ı başarısız tuttuğunu,
iki lockfile'dan biri eksikse taramanın başlamadığını doğrular. Gerçek OSV container
çalışması yerel Docker bulunmadığından GitHub CI'da beklenir.

5 Eylül 2026: AOSP API35 ARM64 emülatöründe dört app journey 4/4; ayrı native platform dosyası 4/4 geçti. Toplam sekiz farklı senaryo iki dosya koşumuyla doğrulandı. HTTP/WS ağ sınırı için beş host regresyonu da geçti. Statik analiz temiz. CI API35 x86_64 sonucu push sonrası ayrıca kontrol edilir; yerel ARM64 sonucu yerine geçirilmez.

Server diliminin sonraki yerel koşumunda **154 Python testi** geçti; bu sayı kaynak/lisans ve çalışma zamanı giriş noktası testlerini de içerir. Bunun içindeki sürüm servisi + gerçek Java/apksig dilimi **51 testtir**; ayrıca bağımsız publisher'ın **13 loopback protokol testi** geçti. Gerçek, hash ile sabitlenmiş AOSP APK fixture'ının imzası ve değiştirilmiş APK'nın reddi doğrulandı; fixture kurulmadı veya çalıştırılmadı. Üretim APK'sı ya da gerçek sunucuya yayımlama yapılmadı.

Client hesabı, kasa, admin ve korumalı giriş için birlikte çalıştırılan altı dosyada **80 unit/widget testi** geçti; bunların **11'i admin controller**, **15'i admin ekranı** senaryosudur. Bu alt adetler 80'e yeniden eklenmez. Kapsam; güncel yönetici rolü, self-demotion sonrası eski tokenların bırakılması, revision/son yönetici çatışması, geçici parola onayı, oturum iptali, işlem günlüğü sayfalaması, PIN/background/idle/hesap/rota geçersizleşmesi ve 320 px / 2× Türkçe metin ile tablet düzenidir. Dokuz hedef üzerinde yapılan ilgili statik analiz temizdir. Bu koşumlar ve ekran önizlemeleri fiziksel tablet, CasaOS, HomePod veya gerçek APK kurulumu kanıtı değildir.

## Gerçek widget önizlemeleri

[server_design_preview_test.dart](../test/shared/server_design_preview_test.dart) mevcut PNG çıkarma mekanizmasıyla ürünün gerçek Flutter ekranlarını, `larenorTheme` ve uygulama fontlarını render eder. Hesap, release metadata, kasa ve kullanıcılar sentetiktir; HTTP yalnız bellek içi `MockClient` üzerinden geçer. Önizleme testleri admin/kasa yazması, APK indirme ve kurulum sayacının sıfır kaldığını doğrular. Görseller elle çizilmiş mockup veya fiziksel cihaz ekran görüntüsü değildir.

| Ekran | Önizleme | Boyut / görünüm |
|---|---|---|
| Server bağlantı formu | [PNG](previews/server-connect-tablet-light.png) | 1280 × 900, açık |
| Doğrulanmış Server hesabı | [PNG](previews/server-account-tablet-dark.png) | 1280 × 900, koyu |
| Kullanıcı yönetimi | [PNG](previews/server-admin-users-tablet-dark.png) | 1280 × 900, koyu |
| Kasa incelemesi; kaydırılmış özet ve açık uygulama düğmesi | [PNG](previews/server-vault-review-tablet-light.png) | 1280 × 900, açık |
| Kullanılabilir Client güncellemesi | [PNG](previews/server-client-update-tablet-dark.png) | 1280 × 900, koyu |
| Dar ekranda kullanıcı yönetimi | [PNG](previews/server-admin-users-phone.png) | 320 × 1000, açık |

Altı önizleme testi başarılıdır; PNG'ler ayrıca görsel olarak kontrol edilmiştir. Önizleme sayısı davranış testlerinin veya cihaz kabulünün yerine kullanılmaz. Üretim komutu:

```sh
flutter test test/shared/server_design_preview_test.dart \
  --dart-define=DESIGN_PREVIEW_DIR="$PWD/docs/previews"
```

## Yerel çalıştırma

Yalnız silinebilir emülatör kullanılır; script fiziksel cihaz seri numarasını ve QEMU olmayan hedefi reddeder. App journey testleri cihaz depolarını bellekte taklit eder; ayrı platform testi kendi native test anahtarlarını yazıp siler. APK kurulumu mevcut emülatör uygulamasını değiştirebilir.

Script temiz checkout için Freezed/Riverpod kaynak üretimini testten önce yapar.
Üretim başarısızsa cihaz ayarlarına ve app journey testlerine geçilmez; üretim
çıktısı da aynı kanıt günlüğüne yazılır. Bu hata kapıları
[hazırlık regresyonlarıyla](../tool/tests/android_e2e_preparation_test.py) sınanır.

```sh
flutter pub get --enforce-lockfile
bash tool/run_android_e2e.sh emulator-5554
```

Paylaşılan aynı checkout içinde Flutter test, analiz ve Gradle derleme komutlarını
sırayla çalıştırın; eşzamanlı işler ortak derleme/cache çıktılarına müdahale edebilir.

Yerel ARM64 AOSP API35 koşumu CI'daki x86_64 koşumunun yerini almaz. CI artifact sonucu ayrıca doğrulanmalıdır. Aktif ürün ve cihaz kabul kapsamı Android tabletler, Huawei MatePad ve Samsung DeX'tir; iOS geliştirmesi ve iPhone/iPad kabulü bu fazın dışındadır. Fiziksel Android cihaz, OS dosya seçicisi ve gerçek oynatma/kapı/kiosk/sağlık izinleri için bu baseline'da başarı iddiası yoktur. Sonraki E2E dilimleri kontrollü fixture sunucularıyla Today/enerji, oda düzenleme, medya request durumu ve gerçek WebView davranışı; fiziksel donanım dilimleri ise ayrı kullanıcı kontrollü cihaz oturumlarıdır.

## Birincil kaynaklar

- [Flutter integration testing](https://docs.flutter.dev/testing/integration-tests): gerçek cihaz/emülatör binding'i ve çalıştırma modeli.
- [Flutter test türleri](https://docs.flutter.dev/testing/overview): unit, widget ve integration ayrımı.
- [Android Emulator Runner v2.37.0](https://github.com/ReactiveCircus/android-emulator-runner/tree/v2.37.0): Linux KVM kurulumu, boot sınırı ve emulator girdileri. Annotated tag'in commit'i `e89f39f1abbbd05b1113a29cf4db69e7540cae5a` olarak primary Git remote'dan doğrulandı.
