# S08.4 — Ev kapsamlı kayıtlar ve açık taşıma sırası

5 Eylül 2026 · Kaynak incelemesi `4b98680`. Bu belge uygulama veya kabul
kanıtı değildir. S08.3'ün yeni dokuz E2E/CI kapısı tamamlandıktan sonra
uygulanacak dar sırayı kaydeder. Çoklu Core/ev federasyonu F19'a aittir.

## Mevcut bağlantılar

- `dashboard/data/dashboard_repository.dart` tek `dashboard_layout` kaydını
  okur/yazar. `dashboard/providers/dashboard_providers.dart` bütün düzen
  mutasyonlarını aynı repository ve `ConfigurationWrites` kuyruğundan geçirir.
  Home dashboard, gezinme ve yerel arama bu provider'ı tüketir. Bu kayıt
  kullanıcının düzenidir; geçici ağ önbelleği gibi silinmemelidir.
- `auth/data/credentials_store.dart` doğrudan HA adresi/token'ını secure
  storage'da tutar. `auth_providers.dart` oturumu; `ha_client_providers.dart`
  REST, WS ve yalnız bellekteki entity durumunu sahiplenir. Mevcut HA yolunda
  kalıcı entity-state önbelleği yoktur.
- `backup/data/backup_repository.dart` aynı legacy düzen anahtarına erişir.
  `backup_snapshot.dart` bağlantı ve ayarlar için sabit allowlist kullanır;
  URL/token tek bağlantı kaydı olarak taşınır. Güvenli rollback journal ve
  yazmadan önce eski provider'ları kaldıran `ConfigurationScope` korunur.
  `home_source_v1` ve Server oturumu yedeğe kendiliğinden eklenmez.
- Diafon, film gecesi ve özel wellbeing kayıtları ayrı sahiplik/politika
  taşır. Cihaz görünümü, güç ve kaynak tercihi ev verisi değildir.

**Somut aktarım riski:** `DashboardLayout` yalnız oda başlıklarından oluşmaz.
HA alanının Server adresini, entity/scene/servis başvurularını ve web panelinin
URL/origin izinlerini taşıyabilir. `dashboard_website_url.dart` query ve
fragment'a izin verir; bu içeriğin sır taşımadığı varsayılamaz. Bazı global
favori/kart başvurularında ev kimliği yoktur. Mevcut S08.3 Core ekran sınırı
otomatik okumayı engeller; repository genişletilirken bu sınır korunmalıdır.

## Uygulama sırası

1. **Kaynaklı düzen deposu ve korumalı önizleme.** Direct yolu mevcut anahtarı
   korur. Core kaydı sürümlü canonical `(coreId, homeId, userId)` anahtarına
   bağlanır; kaydın içindeki tuple da okuma sırasında doğrulanır. Anahtar
   adres/token'dan türetilmez; eksik veya bozuk Core kaydı legacy'ye düşmez.
   Yetki mevcut doğrulanmış hesap oturumundan gelir; disk kimliği veya
   saklanan runtime identity yetki değildir. Repository provider tek seçim
   noktası kalır. PIN korumalı açık önizleme yalnız düzeni okur; HA sırlarını,
   REST/WS veya Core ev dashboard'unu açmaz.
2. **Önizleme ardından sınırlı kalıcı kopya.** İlk dilim yalnız kullanıcının
   açıkça seçtiği oda adı/sırası gibi pasif düzeni kopyalar. Entity, sahne,
   servis, alan bağlantısı ve web URL/izinleri eşleme kanıtı olmadan taşınmaz;
   hariç kalan tür ve sayılar önizlemede görünür. Tam eşleme daha sonraki
   merkezi adaptör sözleşmesini bekler. Önizleme tuple, etkileşim epoch'u,
   kaynak özeti ve hedef revizyonuna bağlı, süreli ve tek kullanımlıdır.
   `ConfigurationWrites` içinde kaynak/hedef ve oturum yeniden doğrulanır;
   tek bounded kayıt yazılır. Legacy silinmez. False/exception yazı başarı
   görünmez; yeniden okuma optimistic preference cache'ini yetki saymaz.
3. **Diğer ev kayıtları ve restore.** Her kayıt kendi politikasına göre
   taşınır. Core restore önizlemesi, onayı ve journal hedefi aynı tuple ve
   revizyona bağlanır; bu S08.5 ile birlikte ayrıca kabul edilir. İlk dilimde
   eski backup yolu Direct kapsamında kalır. Gerçek ağ snapshot önbelleği
   ilk Core read adaptörüyle typed yanıt/TTL/sürüm sınırını kullanır; düzen
   kopyalamak kalıcı ağ cache'inin tamamlanması sayılmaz.

İlk dilimde hesap, CredentialsStore, router veya HomeSessionScope mimarisi
yeniden yazılmaz. Gerekli giriş mevcut SettingsGate altında açılır. Önerilen
yeni sınır `core/home_data_scope.dart` ve home_scope altında önizleme
controller/ekranıdır; mevcut dashboard repository tek sahip kalır.

## Üretim yoluna bağlı RED hedefi

Gerçek HomeSessionScope ve PIN ile legacy düzen/HA sırları varken Core A
açılır: otomatik legacy/sır/ağ okuması sıfır. Kullanıcı önizlemeyi seçince
yalnız düzen okunur. Onay beklerken Core B, kullanıcı, source, pending-context
veya logout değişirse eski callback yazamaz. Yeniden doğrulanmış A'da açık
onay sonrası kopya restartta yalnız A altında görünür. Aynı tuple token
yenilemesi kayıt anahtarını değiştirmez.

Ek vakalar: Direct regresyonu, bozuk/büyük kayıt, yanlış embedded tuple,
restore sırasında kaynak özeti değişimi, false/throw yazı ve EN/TR
600/1200 genişlikte 2× metin. Test hedefleri `test/core/home_data_scope_test.dart`,
`home_session_runtime_test.dart`, dashboard repository ve yeni home_scope
taşıma testleridir. Restore dilimi açıldığında backup/configuration_scope
testleri de genişletilir. Bu araştırmada test çalıştırılmadı; kabul sayacı
artırılmadı, ev servisine veya sırlarına erişilmedi.

## 6 Eylül — Kabul sahipliği ve döngüsüz sıra

S08.4 mevcut kayıtların güvenli kapsam temelidir. İlk pasif oda kopyası yanında
mevcut dashboard, Direct bağlantılar/sırlar, diafon, film gecesi, wellbeing ve
cihaz tercihleri fiili provider/repository erişimiyle incelenir. Her kayıt Core
kapsamlı, Core'dan erişilemeyen Direct veya kişisel/cihaz sahipliğine atanır;
başka ev ve backup allowlist negatif testleri olmadan S08.4 kapanmaz.

Tuple/revision bağlı restore/journal/rollback S08.5'e; sabit oda/kaynak/kişi
kimliği ve izin S08.6'ya aittir. Tam HA eşlemesi ve ilk typed ağ snapshot cache
S08.7'de, medya/müzik S08.8'de, altyapı S08.9'da açık kabul koşuludur. Bunlar
S08.4'ün bitiş önkoşulu yapılmaz: aksi halde S08.4→5→7→4 kabul döngüsü oluşur.
Bu düzenleme kapsamı veya kabul sayısını azaltmaz; her requirement kuyrukta
somut sahibinde kalır. Genel web URL/origin izinleri açık eşleme olmadan
taşınmaz.
