# S07.4 birleşik kurulum durumu ve ayarlar dilimi

Bu dilim, mevcut kalıcı S06.6 kanıtını tablet Ayarları'na taşıyan ve Larenor
Core ile altı yönetilen medya servisini tek, salt okunur görünümde birleştiren
PR-ready yazılım kabulüdür. S07.1 `4e6236e8`, S07.2 ve S07.3 ise
`bf470d95` ile main üzerinde tamamlanmıştır; bu dal güncel main tabanında
yalnız S07.4 farkını taşır. PR #328 bu farkı main'e taşıdı; sonraki exact-tree
incelemesinde bulunan Client kanıt ayrımı `1fcea99a` üzerinde düzeltildi.
S07.4 bu exact commitin tam CI kanıtı birleşene kadar kuyrukta kapanmış
sayılmaz; kuyruk **23/125 (%18,4)** ve seçili özellik sayacı **0/63** kalır.

Tam üç kabul ölçütü vardır:

1. Yalnız dört operator deployment ayarı aynı source revision için byte-stable
   Docker Compose, CasaOS ve manifest üretir. Altı bileşen katalog pinleri,
   canonical ağ/volume sözleşmesi ve LinuxServer `/run` + `/tmp` tmpfs
   sahipliği iki çıktıda aynıdır.
2. Dahili servis adresi veya API anahtarı kullanıcıya sorulmaz. Otomatik ağ
   kimlikleri canonical paketten gelir; salt okunur durum yanıtı Core + altı
   bileşen için `storedState`, `reachableState` ve `verifiedState` kanıtlarını
   birbirinden ayırır. Client yalnız medya ve sağlayıcı ayarlarına yönlendirir.
3. Upgrade preview yalnız exact manifest/owned-path otoritesiyle çalışır;
   backup ve rollback hedeflerini ayırır. Uygulama yürütücüsü olmayan rollback
   veya cancel isteği başarı diye uydurulmaz. Değişmiş bundle, iptal edilmiş
   iş, oturum/rol/route/görünürlük/lifecycle değişimi ve geç yanıt fail-closed
   olur; otomatik komut tekrarı yapılmaz.

## Kanıt matrisi

| Ölçüt | Ürün kanıtı | Otomatik kanıt |
| --- | --- | --- |
| Deterministic tek paket | `deployment_bundle.py` canonical S07.1 Compose'u operator root/timezone/locale/port ayarlarıyla üretir; Docker ve CasaOS aynı tmpfs/manifest otoritesini taşır | `s07_4_unified_install_settings_acceptance_test.py::test_only_operator_settings_produce_one_deterministic_docker_and_casaos_package`; S07.1 bundle/package testleri |
| Secret-free wiring ve geri okuma | Canonical ağ alias'ları otomatik bağlanır; `MediaRecoveryStatusManagement` eksik servisleri açık `missing` satırına dönüştürür ve doğrulanmış readback'i process başlangıcından ayırır | `test_internal_wiring_is_secret_free_and_exact_without_manual_service_addresses`; `test_projection_covers_core_and_all_six_services_from_durable_readbacks`; Client gizli alan/red-order testleri |
| Upgrade/recovery ve stale authority | Preflight exact bundle/manifest/owned-path eşleşmesi olmadan geçmez; Client controller account generation + epoch + route/lifecycle callback'ini bağlar; retained cancel/uncertain sonuç tekrar yürütülmez | `test_upgrade_preview_is_bounded_and_rollback_cancel_or_stale_bundle_fail_closed`; `test_uncertain_cancellation_is_retained_idempotently_across_restart`; account/route geç yanıt testleri |

S07.1'in canonical bileşen kümesi aynı altı servis kimliğini, S07.2 aynı Seerr
→ qBittorrent → Sonarr/Radarr → Jellyfin zincirini ve S07.3 aynı
`music_assistant` kimliğini kullanır. S07.4 bunların ikinci bir state owner'ını
kurmaz; yalnız mevcut kalıcı receipt'lerin salt okunur izdüşümünü sunar. S07.1
paketinin internal URL/token üretimi bu public sözleşmeye taşınmaz.

## Güncel birleşim ve inceleme kanıtı

S07.2 ve S07.3 artık aynı main ağacındadır. S07.4 salt okunur durum yüzeyini
bu kalıcı sözleşmelerden üretir; ayrı bir servis adresi, token veya ikinci state
owner eklemez. Hedefli Server, tool ve Flutter testleri ile analyzer bu exact
dalda yeniden çalıştırılır; tam CI sonucu birleşmeden bu belge kuyruk kapanışı
iddia etmez.

Saldırgan incelemede Client parser'ın Server Pydantic modelinden daha geniş
olduğu bulundu. Artık container/service/result/action/error tutarlılığı iki
tarafta da aynı şekilde doğrulanır; örneğin hata kodu olmayan `failed`, çalışan
container kanıtı olmayan `verified` ve veri doğrulaması olmadan reachable
gösteren belgeler fail-closed olur. Kapatılmış rota üzerinden yakalanmış refresh
callback'i de yeni ağ okuması başlatamaz.
Route veya uygulama arka plana geçtiğinde yakalanmış callback ve görünür durum
geçersizleşir. Aynı exact route tekrar görünür olduğunda ekran kilitli kalmaz;
önceki kanıtı geri kullanmadan yeni bir Core okuması yapar.
Route yetkisi callback'i istisna üretirse de ağ çağrısı başlamaz. İstisna geç
yanıt sırasında oluşursa sonuç bırakılır, `busy` temizlenir ve sonraki geçerli
rota tekrar okuyabilir; callback hatası Client'a taşınmaz.
Durum yanıtı kalıcı kurulum/konfigürasyon receipt'lerini okur; refresh canlı
servis probe'u değildir. Tablet artık `reachable` bilgisini son gözlem olarak
adlandırır ve mevcutsa receipt zamanını gösterir; geçmiş doğrulamayı şu anki
bağlantı erişilebilirliği gibi sunmaz.

PR #328 sonrası bağımsız inceleme, `containerState` ve `serviceState`
değerlerinin Client parser'ında doğrulanıp modelden atıldığını buldu. Böylece
başlamış süreç ile doğrulanmamış entegrasyon tablet satırında açıkça ayrı
görünmüyordu. RED/GREEN kanıtı ve tam yerel matris
[exact-tree kapanış incelemesinde](testing/s07-4-exact-tree-closure-2026-09-23.md)
kayıtlıdır. S07.4 bu nedenle `awaiting_ci` durumundadır.

## Açık kapılar

- **Exact head kapanışı:** `1fcea99a` test ve inceleme kanıtını taşır. Aynı
  commitin zorunlu GitHub CI'ı geçmeden S07.4 sayaç değiştirmez.
- Gerçek apply/rollback yürütmesi S09'un kurulum/güncelleme/yedek kabulüdür.
  S07.4 yalnız desteklenen upgrade preview'ı sunar; yürütücü olmayan rollback
  veya cancel eylemini başarı saymaz.
- Gerçek CasaOS/Proxmox kurulumu, ağ erişimi ve HomePod/Chromecast fiziksel
  kabulü bu yazılım testlerinin yerine geçmez.
