# Client ev kapsamı: S08.3 uygulama sınırı

Bu belge salt okunur keşfin sonucudur. S08.3 kodu henüz uygulanmadı; başlangıç
kapısı S08.2'nin kendi kesin commit'i için CI kabulüdür. S08.1/S08.2'nin hesap
ve doğrulama davranışı, tüm ev ekranlarının veya kalıcı cache'in ayrıldığı
anlamına gelmez. Yürütme durumu [kuyrukta](EXECUTION_QUEUE.md) tutulur.

## Mevcut akış

- `main.dart` → `ConfigurationScope` → `ProviderScope` → `LarenorApp` →
  `routerProvider` → `CupertinoApp.router`. Restore, eski provider'ları ve
  rotaları kaldırdıktan sonra depolamaya yazar. Bu kapsam hesap controller'ını
  da içerir; olağan Core değişimini doğrudan restore gibi ele almak uygun değil.
- `serverAccountControllerProvider` bir `ChangeNotifier` nesnesi döndüren
  düz `Provider`'dır. Nesneyi `ref.watch` ile almak iç bildirimleri izlemez;
  yeni sınır listener yaşam döngüsünü açıkça sahiplenmelidir.
- Server hesabı ayrı Settings yönetim oturumudur. `AppShell`, bugün yerel
  `connectionConfigProvider` üzerinden doğrudan Home Assistant bağlantısıyla
  açılır. Server'da oturum açmak bu HA bağlantısının aynı eve ait olduğunu
  kanıtlamaz.
- `StatefulShellRoute.indexedStack`, oda seçimini ve dört dalın gezinmesini
  korur. `/entities`, `/search`, `/wellbeing` ve Settings, shell dışındaki
  root rotalarıdır; yalnız `AppShell` anahtarını yenilemek bunları kapatmaz.
- HA REST/WS provider'ları dispose sırasında client'ı kapatır. Entity provider'ı
  eski abonelik ve zamanlayıcıları bırakır. `DashboardEditState` ve
  `MediaSessionState`, etkileşim epoch'u ile gecikmiş işlemleri reddeder.

## İlk yararlı teslim

1. **Kaynağı açıkça ayır.** Mevcut doğrudan HA deneyimi `directLocal` olarak
   kullanılabilir kalır. `verifiedCore` deneyimine geçiş eski yerel bağlantıları
   otomatik sahiplenmez. Server hesabına giriş veya çıkış, kaynağı sessizce
   değiştirmez. Kaynak seçimi ve başlangıç davranışı uygulama öncesinde bu
   kurala bağlanmalıdır; URL'den Core/ev kimliği türetilmez.
2. **Kimlik ve epoch sınırı kur.** Doğrulanmış anahtar yalnız
   `(coreId, homeId, userId)` olur; token, kullanıcı görünen adı veya `ServerSession`
   nesne kimliği olmaz. Anahtar yalnız controller'ın doğrulanmış oturumundan
   alınır. Sırlar anahtara, tanılara veya depolama adına yazılmaz.
3. **Hesaptan bağımsız runtime sahiplen.** Account controller ve session store,
   ev sıfırlama alt ağacının dışında kalır. Ev router'ı, provider'ları ve bütün
   root/nested rotaları ayrı sahip olunan `ProviderContainer` içinde yaşar.
   Yalnız iç içe `ProviderScope(key: ...)` yeterli değildir: mevcut Riverpod
   sürümü scope'a özel override/dependency yoksa provider'ı üst container'da
   tutabilir. Ayrı container, dış hesabı `overrideWithValue` ile paylaşabilir;
   paylaşılan hesabın dispose sorumluluğu dışarıda kalır.
4. **Geçişi iki aşamada yap.** Gerçek Core/ev/kullanıcı değişiminde önce eski
   epoch senkron olarak kapatılır; eski callback aynı frame içinde yeniden
   çalışamaz. Sonra eski router/container tamamen kaldırılır ve yeni runtime
   kurulur. Geri tuşu eski entity, oda, arama sonucu veya onay ekranını açamaz.
   Mevcut `ConfigurationScope` restore sırası korunur.
5. **Yenilemeyi kimlik değişimiyle karıştırma.** Başarılı auth POST'undan sonra
   context GET beklenirken controller geçici olarak public session'ı boşaltır.
   Bu ara durum navigator kimliğini değiştirmez: ev görünümü/semantics ve
   etkileşimi kapatılır, hesap kurtarma ekranı kullanılabilir kalır. Aynı tuple
   tekrar doğrulanınca dal/oda/scroll korunur. Farklı tuple eski runtime'ı
   kapatır. Logout/revocation, eski Core görünümünü erişilebilir bırakmaz.
6. **Etkileşim politikalarını birleştir.** Yeni gate, `IdleGate`'in mevcut
   `AppInteractionScope` değerini gölgeleyip idle/background korumasını
   kaldırmamalı. İzin, pencere etkileşimi ve ev doğrulamasının birlikte
   geçerli olmasına bağlıdır. İlk parola, context 404, bozuk yanıt veya context
   bekleme durumunda Core ev ekranı açılmaz; retry yeni auth POST'u üretmez.

## Kalıcı veri ve uyumluluk sınırı

`DashboardRepository` tek `dashboard_layout` anahtarını; `CredentialsStore`
`ha_base_url`/`ha_token` anahtarlarını kullanıyor. Jellyfin ve diğer medya
bağlantıları da yerel kayıtlarını yeniden okuyor. Yeni container oluşturup bu
provider'ları Core B altında aynen mount etmek, eski A verisini geri getirir.

İlk S08.3 teslimi bu kayıtları taşımaz veya silmez. Legacy namespace yalnız
doğrudan yerel kaynak için kalır. Core bağlamına bağlı cache/adaptör henüz
hazır değilse Core görünümü açık bir kullanılamıyor durumu gösterir; legacy
dashboard/medya provider'ları o Core'a aitmiş gibi kurulmaz. Cache anahtarları,
taşıma önizlemesi ve merkezi HA/medya adaptörleri ayrı S08.4+ işleridir.
Yerel ses veya ilerideki kişisel uzak bağlantılar sırf Server yönetim hesabı
değişti diye Core verisi sayılmaz; kaynak sahipliği açık olmalıdır.

## Önerilen dar dosya sahipliği

- Yeni `lib/core/home_session_scope.dart` ve `test/core/home_session_scope_test.dart`:
  anahtar, epoch, pending/retired sınırı ve container sahipliği.
- `lib/app.dart`, `lib/core/router.dart`, gerekirse
  `lib/features/server/providers/server_providers.dart`: dış hesap ve iç
  runtime bağlantısı; bütün ikincil rotaların kapsanması.
- `lib/core/app_interaction_scope.dart` ve gerektiğinde
  `lib/features/settings/presentation/idle_gate.dart`: mevcut pencere politikası
  ile context geçidinin bileşimi.
- `lib/features/auth/providers/auth_providers.dart`,
  `lib/features/navigation/presentation/app_shell.dart`, gerekli EN/TR metinleri:
  doğrudan HA/Core kaynak ayrımı ve legacy provider'ın Core'a açılmaması.
- Mevcut navigation/configuration-scope testleri: gerçek route, restore ve
  etkileşim regresyonu. Dashboard repository/cache taşıması bu ilk sahiplikte yok.

Bu liste uygulama için öneridir; keşif sırasında hiçbir üretim dosyası
değiştirilmedi ve test çalıştırılmadı.

## Runtime RED kabul senaryoları

- A evinde oda/entity rotası ve root onayı açıkken B doğrulanır. Eski callback
  frame beklemeden tekrar çağrıldığında işlem göndermez; eski rota ve back stack
  kapanır. Eski provider'ın dispose edildiği, B kurulmadan önce gözlenir.
- Bekleyen A REST sonucu ve eski WS olayı geç döner; B ekranına, cache'ine veya
  eylem sonucuna yayınlanmaz. Eski client/abonelik/zamanlayıcı bırakılır.
- Aynı tuple için token rotasyonu ve context beklemesi, dal/oda/scroll ve dış
  account controller kimliğini korur; pending sırasında eski onay kullanılamaz.
- Aynı Core/evde farklı kullanıcı da sıfırlar. İlk parola/404/401/bozuk context
  Core home'u açmaz; bağlam retry'si yalnız GET'tir.
- Doğrudan HA, Core olmadan çalışır. Server hesabı açılması legacy veriyi
  otomatik Core'a bağlamaz; Core logout'u sessiz direct-HA fallback yapmaz.
- Restore, Settings PIN/native picker yeniden doğrulaması, idle/background,
  tablet pencere değişimi ve mevcut doğrudan HA gezinmesi korunur.

Bu testler gerçek repository/provider/router akışını sentetik API/WS ile
çalıştırmalı; yalnız yeni sınıfın kendi alanlarını tekrar eden testlerle kabul
verilmemelidir. Canlı ev veya cihaz üzerinde işlem gerektirmez.
