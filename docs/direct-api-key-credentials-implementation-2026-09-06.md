# S08.4 — Direct Jellyseerr, Bazarr ve Prowlarr kayıt sınırı

6 Eylül 2026. Başlangıç `0298c5ae5d962eccddc0abeaa19cb551a2f5d943`,
izole dal `codex/direct-api-key-credentials`. Davranış kaynağı `920f09f`;
son source/test dondurması `dcfb1a5ac578251d7cb511f843d01947b4755354`.
Son üretim farkı yalnız formatter; ortak form guard davranışı değişmedi.
Bu paket üç API anahtarı tüketicisini mevcut ortak kayıt sözleşmesine bağlar.
S08.4'ün tümü veya kalan Jellyfin/qBittorrent/Keenetic/Proxmox tüketicileri
bu paketin kabulü değildir. qBittorrent başka bir izole pakette ele alınır.

## Kayıt ve sahiplik

Üç mevcut public store constructor'ı ve typed config modeli korunur;
store'lar isteğe bağlı Direct sahipliği alır. Üretim provider'ı bu sahipliği
`directHomeAccessProvider` üzerinden zorunlu bağlar. Kapsamsız eski store
kullanımı uyumludur. Ortak `DirectCredentialRecord`, HA store, auth, backup,
EnabledServices ve kaynak kapsamı değiştirilmedi.

Kapalı servis eşlemesi sırasıyla baseUrl/apiKey alanlarını ve özel
`jellyseerr_connection_pending_v1`, `bazarr_connection_pending_v1`,
`prowlarr_connection_pending_v1` marker'larını kullanır. Okuma, tam değiştirme
ve temizleme mevcut `ConfigurationWrites` içinde sıralanır. Her platform
etkisi öncesi/sonrası sahiplik ve varsa form eylem izni kontrol edilir.
Store, helper await'inden döndüğünde ayrıca kendi tutulan sahibini denetler.
Bu ek continuation kontrolü savunmadır; per-platform testleri tam bu microtask
aralığının özel RED kanıtı değildir.

Marker ilk alan etkisinden önce yazılır; yalnız tam başarı ve güncel izin
sonrası silinir. Marker varken eski/yeni URL-key karışımı okunmaz. Hatalar
statiktir; otomatik rollback, retry veya marker temizliği yapılmaz. Platformun
son marker silmesini gerçekleştirip yanıtını kaybetmesi halinde işlem hâlâ
başarısız bildirilir, fakat yeni store gerçek tam kaydı okuyabilir. İlk marker
etki öncesi hata alırsa eski tam kayıt kalabilir. Aradaki belirsiz etkiler marker
ile kapanır ve yalnız açık tam save veya clear ile kurtarılır. Bu native
Keychain/Keystore transaction, fsync veya fiziksel süreç yeniden başlatma
kanıtı değildir.

## Bağlantı eylemleri ve UI

Connection notifier ilk Direct sahibini ve işlem kuşağını tutar. Eski login
ve logout Core'a veya yeni Direct kuşağına yayın/write/delete yapamaz.
Tek kullanımlık check client success/error/source disposal sonunda kapanır.
Mevcut Jellyseerr `/api/v1/auth/me`, Bazarr `/api/system/status` ve Prowlarr
`/api/v1/system/status` kontrolleri korunur. HTTP parser veya hizmet kontrol
protokolü değişmedi. Client provider, yeni config yüklenirken eski AsyncValue
verisini kullanmaz; Bazarr/Prowlarr için bu ayrıca gerçek RED ile doğrulandı.
Direct arka plan okuması sırf pencere etkileşimi boşta diye engellenmez.

Üç ConnectScreen, mevcut korumalı ArrConnectForm'u kullanır. Ortak formdaki
tek davranış dışı API genişlemesi optional `apiKeyHint` alanıdır; eski Arr
varsayılanı aynıdır. Üç servis kendi mevcut Settings → General yönergesini
korur. Formun PIN/source/route/TickerMode/lifecycle/interaction epoch ve
`isCurrent` sözleşmeleri değişmedi. Wrapper kendi exact notifier'ını açık
route boyunca dinler; HTTP ve platform etkileri formun güncel iznini taşır.

Yalnız `pending_mutation`, gerçek PIN Settings → Integrations → Manage
Integrations yolunda boş kurtarma formunu açar. Eski URL/key prefill yoktur;
bu form LAN discovery başlatmaz. Kullanıcı tam bağlantıyı açıkça kaydedebilir
veya Remove saved connection ile temizleyebilir. Başarılı clear formu boş
bırakır, otomatik discovery/reload yapmaz. Diğer storage hataları yerelleştirilmiş
güvenli genel hata olarak kalır. Standalone başarılı bağlantının kendi push
route'undan üst route'a dönmesi ayrıca sınanır; parent screen'in formu gizlemesi
tek başına başarı kanıtı sayılmaz.

## RED → GREEN checkpoints

| Dilim | Runtime RED | Minimal GREEN |
|---|---|---|
| Core/pending/error, held store ve özel marker | `2726f0d`: 30 FAIL / 6 PASS | `4a06891`: 36 PASS |
| Geç login/logout, client ömrü ve reload | `811c73f`: 17 FAIL / 7 PASS | `2346025`: 60 birleşik PASS |
| Gerçek PIN recovery ve standalone cold Core | `74118f9`: 12 FAIL | `920f09f`: 12 PASS |

İlk action fixture, config yüklenmeden read provider'ın boş liste cevabını
beklediği için üç yanlış HTTP sayısı hatası içeriyordu. `811c73f`, gerçek
connection subscription/future tamamlandıktan sonra aynı kaynak üzerinde
runtime RED'i yeniden kaydetti; ilk 18 FAIL sonucu üretim bulgusu diye
sunulmaz. Loglar ayrı adlarla saklanır.

## Yerel kabul kanıtı

- **151 yeni odaklı PASS**, 4 saniye. Üç standalone Navigator push → başarılı
  bağlantı → original route dönüşü dahildir; `canPop`, görünür route, tek HTTP
  ve marker temizliği ayrı ayrı doğrulanır.
- **192 mevcut Arr regresyonu PASS**, 3 saniye. Optional hint varsayılanı ve
  ortak formun source/callback/lifecycle davranışı korunur.
- **241 birleşik ilişkili PASS**, 6 saniye: 151 yeni test ile üç servisin
  mevcut client/model/session UI testleri, media hub/session, EnabledServices
  ve ServerBoundClient regresyonları. Sayılar toplanarak benzersiz 584 test
  iddia edilmez; 151 odaklı test birleşik koşuda tekrar yer alır.
- **16 dosya analyze: 0 bulgu**; formatter 16 dosya, 0 değişiklik;
  `git diff --check` temiz. İlk analyze yalnız altı test brace uyarısı verdi;
  bunlar düzeltilip analiz ve ilişkili testler tekrar geçti.
- Birleşik LCOV: değişen **13 tam üretim dosyası 573/712 = %80,5 satır**.
  Üç büyük home/indexer ekranı hariç store/provider/connect/shared form
  sınırının **10 dosyası 372/411 = %90,5**. Üç store 36/36, üç connect
  wrapper 60/60. Git diff'inde eklenen ölçülebilir satırlar 221/242 = %91,3.
  Bu line coverage ölçümüdür; branch coverage iddiası değildir. Değişmeyen
  medya eylemleri dahil tam ekran paydası ayrıca saklanır.
- Gerçek Inter fontu, EN/TR, 600×900, 2× metin ve light/dark recovery
  düzenleri taşmadan çalışır. Mevcut servis hint'leri, boş prefill ve açık
  clear sonrası Done doğrulanır; bu paket özel PNG/cihaz QA iddia etmez.

Kanıtlar `/private/tmp/larenor-direct-api-key-` önekiyle: `store-red.log`,
`store-green.log`, `actions-runtime-red.log`, `actions-green-final.log`,
`recovery-red.log`, `recovery-green.log`, `expanded.log`, `pop-green.log`,
`final-focused.log`, `arr-regression.log`, `final-broad.log`,
`final-analyze.log`, `final-format.log`, `final-coverage.info`,
`broad-coverage.info`, `coverage.json`. Odaklı ve broad LCOV dosyaları ayrı
saklanır; rapordaki %80,5 son broad koşusuna aittir.

Bütün platform etkileri gerçek plugin MethodChannel arayüzündeki sentetik
backend, HTTP ise mevcut gerçek client sınıfları ve MockClient üzerinden
çalıştırılır. NetworkInfo fixture'ı null döndürür; gerçek subnet/LAN taraması
yapılmaz. Cold Core testleri provider graph'ında secure-store ve HTTP factory
sayılarını kontrol eder; fiziksel SharedPreferences getAll okuma sıfır iddiası
yoktur. Yeni store örneği, aynı sentetik platform verisinin tekrar okunmasını
kanıtlar; native process/disk restart veya ev hizmeti kabulü değildir.

Bu izole dal push edilmez. Yeni ortak backup guard'ının birleşik kabulü, tüm
Client regresyonu ve exact GitHub CI root tarafından ayrı doğrulanır.
