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
