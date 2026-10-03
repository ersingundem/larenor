# F19 iki bağımsız normal Core kabulü

Bu kabul, production `ServerAccountController`, sürümlü profil kasası ve
`ServerServicesApi` ile iki ayrı normal Core veritabanını kullanır. Her Core'a
ayrı admin oturumu ve ayrı Jellyfin credential kaydedilir. Client her profil
seçiminde yalnız o Core'un `/admin/services` cevabını görür; Core/home
kimlikleri, tokenlar ve service satırları birleşmez.

Owned TCP fixture yalnız authenticated `GET /System/Info` kabul eder ve
`X-Emby-Token` değerini iki sabit test credential'ından biriyle eşler. Dönen
`ProductName`, `Version` ve `StartupWizardCompleted` alanları Jellyfin'in
resmî `SystemApi.getSystemInfo` / `SystemInfo` sözleşmesidir:
[System API](https://typescript-sdk.jellyfin.org/classes/generated-client.SystemApi.html#getSystemInfo),
[SystemInfo modeli](https://kotlin-sdk.jellyfin.org/dokka/jellyfin-model/org.jellyfin.sdk.model.api/-system-info/).
Fixture fiziksel ev servisine bağlanmaz ve mutation endpointi sunmaz.

`server/tests/support/f19_flutter_acceptance.py` sekiz ayrı Flutter ömrü
çalıştırır. Her ömür aynı tek named testi tam bir kez çalıştırmalı ve skip
üretemez:

1. `prepare`: Flutter Client Core A ve Core B'ye giriş yapar, her birinde farklı Jellyfin
   service oluşturup gerçek TCP probe ile authenticated readback alır, bağımsız
   Core/home kimliklerini doğrular, cross-home authority kapısını çalıştırır ve
   iki profil arasında geçerken yalnız doğru service'i görür. Her Core'un gerçek
   `/media/catalog/target` ve `/media/catalog/search` cevabı farklı bir başlık
   döndürür. Production katalog controller/cache yolu A ve B için önce `live`,
   sonra `verifiedCache` sonucu verir; tekrar geçişte diğer profil cache'i hiçbir
   zaman yayınlanmaz.
2. `negative_authority`: Core A kendi geçerli A tokenını kabul eder fakat `/context`
   cevabında B Core/home kimliğini döndürür. Cross-home doğrulama
   `independent_authorization_required` ile kapanır; aktif B session/profile ve
   service görünümü değişmez, A katalog sonucu yayınlanmaz.
3. `duplicate_restore`: prepare kasasının private kopyasına ikinci profil kimliği
   altında aynı Core/home/user authority tuple'ı eklenir. Production
   `ServerHomeRegistry.decode` bunu `invalid_session` olarak reddeder; Client
   session/profile yayınlamaz ve Core/provider okuması yapmaz. Bu erken decode
   sınırı, daha geç `_persistBoundSession` identity birleştirme/çatışma yoluna
   bozuk restored state'in ulaşmasını engeller.
4. `restart`: Client yeniden başlar, aynı sürümlü profil kasasını okur. Core A kapatılmıştır;
   Client aktif Core B'yi kullanmaya devam eder. A'ya geçiş fail-closed olur ama
   iki profil silinmez; B'ye geri geçiş ve service okuması başarılıdır.

Aradaki dört cancellation ömrü `cancel_source_me`,
`cancel_source_context`, `cancel_target_me` ve `cancel_target_context` adlarını
taşır. Runner yalnız seçili normal Core GET'ini private loopback kapısında
bekletir. Client aktif B profilinden A için cross-home authorization başlatır,
gerçek isteğin kapıya ulaştığını görür, production `cancelPending()` yolunu
çalıştırır ve sonra geç yanıtı serbest bırakır. Her faz, cancellation sonrasında
aynı B session/profile/registry authority'sinin kaldığını ve B service
projection'ının değişmediğini doğrular. Core A/B catalog worker çağrı sayıları
değişmemelidir; geç yanıt katalog veya provider sonucu yayınlayamaz.

`server_home_profile_limit_test.dart` ayrıca üç production sınırını birlikte
çalıştırır: 16 kayıtlı profilde gerçek `ServerHomeProfilesScreen` add düğmesi
disabled olur; doğrudan `ServerAccountController.beginAddProfile()` çağrısı
`profile_limit` yayınlarken aktif session/profile/generation'ı ve registry
byte'larını değiştirmez, Core API çağrısı yapmaz; active seçimi olmayan dolu
`SecureServerSessionStore` on yedinci session'ı yazmadan aynı hata ile reddeder.

Testte kullanılan `_FileRegistryStore`, encrypted platform secure store yerine
owned 0700 geçici dizindeki plain test dosyasıdır. Duplicate restore production decoder'ı ve
controller'ın fail-closed davranışını çalıştırır; Android Keystore/iOS Keychain,
backup restore ve fiziksel cihaz secure-storage davranışını kanıtlamaz. Katalog
cevapları normal Core HTTP API'sinden gelir; private archive worker fixture'ı
source-bound, process-local veridir ve fiziksel Jellyfin taramasını kanıtlamaz.

Bu scoped yazılım kanıtı gerçek iki ev ağı, Headscale ACL, fiziksel Jellyfin,
platform secure storage, tam eşzamanlı/backup identity matrisi veya required CI
sonucunu kanıtlamaz. Bunlar ayrı CI/saha kapılarıdır; bu test sonucu tek başına
F19 full acceptance değildir.

Platform secure-store limiti FlutterSecureStorage'ın test platform sınırında
gerçek production registry codec/store ile çalışır. Android Keystore/iOS
Keychain donanımı, backup restore ve fiziksel cihaz secure-storage davranışı
bu local yazılım kanıtının dışındadır.

## Root execution proof, 2026-10-03

Exact source `3f86082026624d8de6b13c037de203e0c938c158` was executed by the root in a disposable, supervised loopback fixture. The named F19 runner completed both prepare and restart Flutter lifetimes successfully, using two normal Core databases, distinct identities and an owned read-only Jellyfin HTTP fixture. All supervised commands completed with exit 0. The closed execution record contains these private log hashes; no credential or raw provider log is published:

- `f19-two-core-tcp`: SHA-256 `71aae47200b6c92c50c9402fc23242cbe23099f6276aecac0fdcd96e6e376965`.

These are scoped software test results. The two owned Cores run in one supervised process and use a test file-store profile registry. This does not establish platform secure-storage behavior, actual Headscale/physical homes, the complete concurrent/backup-identity failure matrix or real Jellyfin installation effects. Final combined exact-commit CI, independent acceptance review and dependency closure remain required. No item is promoted to accepted or merged.

Bu historical kayıt yalnız o commit'teki eski iki ömürlü prepare/restart
runner'ını kapsar. Yukarıdaki `negative_authority`, `duplicate_restore` ve
profil-scope catalog/cache kontrolleri için yeni candidate source üzerinde ayrı
named sonuç gerekir; eski log hash'i bu yeni kapıların kanıtı değildir.

## Current eight-phase shared-source root proof

Root verified the five frozen base/candidate file hashes and all eight machine report hashes with the production strict named validator. Each machine report contained exactly one visible pass, zero failures/errors/skips; the source includes separate source/target me/context gates. Root then executed the integrated shared runner through all eight phases (exit 0), terminal log SHA-256 `30ba897fe37c83d70fc7701b986683ba87fa9bb28b5e97014e57279297b10e6d`; the real production 16-profile UI/controller/store gate passed 2/2, log SHA-256 `acb883a1e39631da48bc49b5fc8350aac65e15c6beba53f32e69586c39e5e565`.

Independent read-only review found no P1/P2 within this software scope. Controller limit guard runs before generation/session/API retirement. Each cancellation phase advances production generation before its delayed normal HTTP response is released and preserves B profile/session/registry and zero new catalog/provider calls. Production decode rejects duplicate restored authority before publication. Frozen manifest SHA-256 `7a81e4b37278b5ed770de5b30be97fc5167e42869ea53aac47b6d624d37fc48d` binds the reviewed source and eight individual report hashes. Final exact-source required CI and acceptance dependencies still remain; no platform secure-storage or physical Jellyfin/home effect is claimed.

Root shared Flutter analysis of the changed controller and three Client lifecycle test files completed with no issues; terminal log SHA-256 `68977f52316d1db3bac7606d3f72fb1f5bc30b26a304849565be78a0b25761d1`. This is scoped local analysis, not hosted CI acceptance.
