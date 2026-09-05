# S08.4 — Direct Arr kimlik kaydı ve kurtarma sınırı

6 Eylül 2026. Başlangıç `cc0d89dafd12cf20a76f80c38e6cfa382be59ebd`,
izole dal `codex/direct-arr-credentials`. Üretim/test dondurması
`e980b8d5c0b70ab647bf32ea05149d6ad7ea238a`.
Bu paket Sonarr, Radarr, Lidarr ve Readarr tüketicilerini kapsar; bütün S08.4
veya 11 servisin tamamı için kabul değildir.

## Kayıt sözleşmesi

`DirectCredentialService` 11 mevcut servisin kapalı alan/anahtar eşlemesini
ve `${service.name}_connection_pending_v1` özel marker kimliklerini tanımlar.
Bu pakette sadece dört Arr store/provider bu sözleşmeye taşındı. Diğer yedi
servisin enum/alan testleri yalnız gelecekteki ortak sözleşmeyi doğrular;
mevcut tüketicilerinin Direct sahipliğiyle korunduğunu göstermez.

`DirectCredentialRecord.readFields()`, `replaceAll(fields, {isCurrent})` ve
`clear({isCurrent})` işlemleri `ConfigurationWrites` ile sıralanır. Yazı için
çağıranın alan haritası kuyruğa girmeden dondurulur; kapalı tam alan kümesi
zorunludur. Marker ilk alan etkisinden önce yazılır. Sabit sırada bütün alan
etkileri ve güncellik kontrolleri tamamlanınca marker kaldırılır. Okuma,
marker varsa URL veya API anahtarını okumadan statik `pending_mutation` ile
kapanır. Hata otomatik rollback, retry, marker temizliği veya başka bir
servisin alanlarına erişim başlatmaz.

Platform yanıtı başarısız olduğunda yazının gerçekleşmediği varsayılmaz.
İlk marker yazısı etki öncesi başarısızsa eski tam kayıt kalabilir. Son marker
silme yanıtı kaybolmuşsa tam yeni kayıt veya tam silinmiş kayıt gerçekte
mevcut olabilir; işlem yine başarısız bildirilir. Aradaki yarım etkilerde marker
kalan karışık kayıt yeni store örneğinden de kullanılamaz. Bu native Keychain/
Keystore transaction veya disk fsync garantisi değildir.

Arr store üretim provider'ından alınırken mevcut `directHomeAccessProvider`
sahipliğine bağlanır. Core, pending/başlangıç hatası, emekliye ayrılmış provider
ve kaynak dönüşünde eski nesne read/save/clear ile erişimi yeniden kazanamaz.
Kapsamsız eski store kullanımı korunur. `servicePrefix` public parametresi
kalır, fakat yalnız dört bilinen Arr değeri kabul edilir; bilinmeyen prefix
platform I/O öncesi statik `ArgumentError('unsupported_service')` üretir.

ArrStore.read'in helper await'inden sonraki continuation'ında ayrı sahiplik
kontrolü vardır. Bu kontrol bağımsız inceleme sonrası savunma olarak eklendi;
per-platform source-change testleri tam bu microtask aralığının özel RED
kanıtı olarak sunulmaz.

## Eylem ve kurtarma

Dört connection notifier ilk Direct sahibini ve işlem kuşağını tutar. Geç
HTTP sonucu yeni store edinip oturum yayımlayamaz; eski logout yeni kaydı
silemez. Eşzamanlı ikinci login `busy` olur; açık logout önceki kontrolü
emekliye ayırır. Tek kullanımlık kontrol istemcisi success/error/dispose
sonunda kapatılır. Mevcut servis protokolü ve read-only bağlantı kontrolü
korunur; bu paket yeni sunucu kimlik doğrulama protokolü getirmez.

Form source/route/TickerMode, native lifecycle ve AppInteraction epoch
kontrollerini kullanır; eski callback, yeni taslak doldurulmuş olsa bile
idle→wake, gizlenme, route dönüşü, kaynak dönüşü, callback değişimi veya dispose
sonrasında çalışmaz. Pencere izni yalnız görsel sonucu saklamaz: formun
`isCurrent` koşulu notifier HTTP kontrolü sonrasına ve her tekil platform
credential yazısı öncesi/sonrasına taşınır. Direct arka plan okumaları sırf
etkileşim boşta diye reddedilmez. Mevcut PIN ve medya eylem kapıları korunur.

Yalnız `pending_mutation` hatası PIN korumalı Settings → Integrations → Manage
Integrations → ilgili servis yolunda boş kurtarma formunu açar. Eski URL/key
önceden doldurulmaz; bu form LAN discovery başlatmaz. Kullanıcı tam URL/key
ile açık yeniden bağlanabilir veya kayıtlı bağlantıyı kaldırabilir. Kaldırma
captured bound store üzerinde tam clear çalıştırır; form boş kalır ve Done
bildirir. Otomatik provider invalidate/reload yapılıp varsayılan keşfe geçilmez.
Diğer depo hataları güvenli genel hata olarak kalır. Görünür hata metinleri
platform cevabı veya credential içeriğini taşımaz.

## RED → GREEN

| Dilim | Runtime RED | İlk GREEN |
|---|---|---|
| Core/pending/error ve kapalı marker kaydı | `e7658b5`: 21 FAIL / 4 PASS | `0abf0f4`: 25 PASS |
| Geç login/eski logout ve client ömrü | `46bf2c1`: 16 FAIL | `4892b8e`: 41 birleşik PASS |
| PIN settings üzerinden boş kurtarma | `7f6efe8`: 4 FAIL | `ebb04bf`: 4 PASS |
| Form callback/lifecycle, cold Core discovery | `5475646`: 9 FAIL / 1 PASS | `dcb7458`: 14 birleşik PASS |
| HTTP/ilk alan yazısında pencere izni kaybı | `d2b5f60`: 2 FAIL / 4 PASS | `e1caccb`: 155 birleşik PASS |
| Açık kayıt kaldırma | `c291b57`: 4 FAIL / 10 PASS | `2710942`: 24 form/kurtarma PASS |

Form testinin ilk compile denemesinde test-only `const` constructor hatası
vardı; bu runtime RED sayılmadı. Runtime RED background vakası hem gerçek eski
callback çağrısını hem hatalı paused→resumed fixture geçişini içeriyordu;
fixture, GREEN öncesinde gerçek inactive/hidden/paused/hidden/inactive/resumed
sırasına düzeltildi. İlk kurtarma GREEN denemesindeki health-clock teardown
hatası container test invariant kontrolünden önce dispose edilerek giderildi.
Başarısız loglar saklandı; son GREEN logları ayrı ad taşır.

## Son yerel kanıt

- **192 odaklı PASS**, 5 saniye: beş yeni test dosyası. Gerçek secure-storage
  MethodChannel platform sınırı; sentetik HTTP `runWithClient`/MockClient;
  gerçek HomeSessionController, provider, PIN settings route ve dört Arr ekranı.
- **547 ilişkili PASS**, 18 saniye: Arr, Direct sahipliği/lifecycle,
  EnabledServices, mevcut backup, media hub ve bağlı network regresyonları.
  Bu koşu son yedi form QA/error/keyboard testi öncesindedir; son delta 192
  odaklı koşu ile ayrıca doğrulandı. Yeni backup marker pilotu bu worktree'ye
  birleşmediğinden onun birleşik kabulü root'un ayrı adımıdır.
- **16 dosya analyze: 0 bulgu.** Formatter ve `git diff --check` temiz.
- Son odaklı LCOV, değişen 11 üretim dosyası için **531/615 = %86,3 satır**.
  Helper 59/59, ArrStore 19/19; dört provider toplam 250/258; form 122/127.
  Aynı koşudaki dört tam screen dosyası 81/152: değişmeyen dashboard/normal
  bağlantı dalları dahil. Bu line coverage ölçümüdür, branch coverage iddiası
  değildir.
- EN/TR, light/dark, 600×900 ve 2× metinle gerçek Inter fontlu dört kurtarma
  düzeni; erişilebilir kaldırma kontrolü, gerçek Tab/Enter/Space işlemleri,
  aktif hata sonrası açık retry ve eski clear callback reddi geçti.

Yerel kanıt dosyaları `/private/tmp/larenor-direct-arr-` önekiyle:
`store-red.log`, `store-green.log`, `actions-red.log`, `actions-green.log`,
`recovery-red.log`, `recovery-green-final.log`, `form-runtime-red.log`,
`form-green-final.log`, `window-effect-red.log`, `window-effect-green.log`,
`explicit-clear-red.log`, `explicit-clear-green.log`, `broad.log`,
`final-focused.log`, `final-analyze.log`, `final-coverage.info`.

Canlı HA/LAN/medya servisine erişilmedi; fiziksel cihaz veya native process
restart testi yapılmadı. Yeni store örneğiyle okuma, platform fixture'ında
sürekliliği temsil eder. Bu izole dal push edilmedi; exact GitHub CI, ortak
backup birleşimi ve bütün Client regresyonu root tarafından ayrıca yürütülür.
