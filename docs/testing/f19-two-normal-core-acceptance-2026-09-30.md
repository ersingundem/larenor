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

`server/tests/support/f19_flutter_acceptance.py` iki aşama çalıştırır:

1. Flutter Client Core A ve Core B'ye giriş yapar, her birinde farklı Jellyfin
   service oluşturup gerçek TCP probe ile authenticated readback alır, bağımsız
   Core/home kimliklerini doğrular, cross-home authority kapısını çalıştırır ve
   iki profil arasında geçerken yalnız doğru service'i görür.
2. Client yeniden başlar, aynı sürümlü profil kasasını okur. Core A kapatılmıştır;
   Client aktif Core B'yi kullanmaya devam eder. A'ya geçiş fail-closed olur ama
   iki profil silinmez; B'ye geri geçiş ve service okuması başarılıdır.

Bu yazılım kabulü gerçek iki ev ağı, Headscale ACL veya fiziksel Jellyfin
kurulumunu kanıtlamaz; bunlar saha kapısıdır.

## Root execution proof, 2026-10-03

Exact source `3f86082026624d8de6b13c037de203e0c938c158` was executed by the root in a disposable, supervised loopback fixture. The named F19 runner completed both prepare and restart Flutter lifetimes successfully, using two normal Core databases, distinct identities and an owned read-only Jellyfin HTTP fixture. All supervised commands completed with exit 0. The closed execution record contains these private log hashes; no credential or raw provider log is published:

- `f19-two-core-tcp`: SHA-256 `71aae47200b6c92c50c9402fc23242cbe23099f6276aecac0fdcd96e6e376965`.

These are scoped software test results. The two owned Cores run in one supervised process and use a test file-store profile registry. This does not establish platform secure-storage behavior, actual Headscale/physical homes, the complete concurrent/backup-identity failure matrix or real Jellyfin installation effects. Final combined exact-commit CI, independent acceptance review and dependency closure remain required. No item is promoted to accepted or merged.
