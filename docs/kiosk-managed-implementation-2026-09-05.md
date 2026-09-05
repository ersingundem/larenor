# Yönetilen kiosk temeli — 5 Eylül 2026

Larenor Client artık Android'in cihaz sahibi yetkisini, görev kilidi iznini ve gerçek çalışma durumunu okuyabilir. Normal kişisel tablette bu sayfayı açmak ayar değiştirmez. Yönetilen kiosk için ayrılmış cihaz/kurumsal yönetici izni gerekir. Fiziksel cihaz kaydı, silme, yeniden başlatma veya Home Assistant işlemi bu çalışma sırasında yapılmadı.

## Uygulanan sözleşme

| İşlem | Önkoşul ve sonuç |
| --- | --- |
| Durumu yenile | Salt okunur `DevicePolicyManager` / `ActivityManager`; bilinmeyen değerler izin veya kilit gibi gösterilmez. |
| Larenor'a izin ver | Larenor'un kendi receiver'ı cihaz sahibi olmalı. Yalnız kendi paketini mevcut izin listesine ekler; diğer paketler korunur. |
| Larenor iznini kaldır | Yalnız kendi paketini çıkarır. Yönetilen görev kilidini de sonlandırabilir; UI bunu onaydan önce açıklar. |
| Güç menüsünü geri getir | Yalnız kendi yönetiminde `GLOBAL_ACTIONS` bitini ekler. Başka feature bitini silmez. Menü kapalıysa kendi yönetilen kurulumunda giriş engellenir. |
| Yönetilen kioska gir | Android görev kilidi izni iki kez doğrulanır. Ana/odaktaki/resumed pencere, bilinen yönetim durumu ve kilidi açık cihaz gerekir. İzin yokken `startLockTask()` çağrılmaz; ekran sabitlemeye düşülmez. |
| Görev kilidinden çık | Açık kullanıcı eylemi ve yeni PIN gerekir. İzin listesinden çıkarılmış, harici ekrandaki veya artık device owner olmayan durumda da çıkış engellenmez. Android bu Activity'nin çıkmasına izin vermiyorsa harici yöneticinin kurtarma yolu gerekir. |

`LOCK_TASK_MODE_PINNED`, kullanıcının sonlandırabildiği ekran sabitlemedir; `LOCK_TASK_MODE_LOCKED` yönetilen görev kilididir. İsteğin dönmesi hedef durumun oluştuğu anlamına gelmez. UI **gözlemlendi**, **kabul edildi ama henüz gözlemlenmedi**, **sonuç belirsiz** ayrımını korur; komut otomatik tekrarlanmaz. [Android görev kilidi](https://developer.android.com/work/dpc/dedicated-devices/lock-task-mode)

## Onay ve platform sınırı

Her yönetim eyleminde mevcut Ayarlar PIN'i yeniden, kalıcı deneme sınırıyla doğrulanır. PIN yoksa yönetim yapılmaz; mevcut SettingsGate oturumunun açık olması onay sayılmaz. PIN doğrulaması sırasında PIN'in kaldırılması/değişmesi, idle, arka plan, gizlenen route veya dispose eski işlemi geçersiz kılar. PIN platform kanalına iletilmez, yedeklenmez, loglanmaz.

Native katman ayrı bir rastgele, 30 saniyelik, monotonic saate bağlı ve tek kullanımlık işlem önerisi üretir. Native pause/focus/configuration değişimi bunu iptal eder; işlemden hemen önce yetki ve pencere tekrar okunur. Terk edilmiş süresi dolmuş öneri sonraki kurtarma işlemini bloke etmez. MethodChannel yalnız bu uygulamanın Flutter engine'i içindir; ayrı bir uzaktan yönetim API'si değildir. Uygulama süreç içi kodunun ele geçirilmesine karşı bağımsız bir PIN güvenlik sınırı iddiası yoktur.

`KioskAdminReceiver` exported olmalıdır ancak `android.permission.BIND_DEVICE_ADMIN` ile yalnız sistem erişimine açıktır. Boş `uses-policies` kaydı; force-lock, wipe-data, parola veya kamera yönetimi istemez. Receiver callback'leri yönetim değişikliği başlatmaz. Intent extras ile kiosk komutu, boot receiver, otomatik startLockTask, kalıcı Home seçimi, uygulama kaldırmayı engelleme veya erişilebilirlik servisi eklenmedi. [DeviceAdminReceiver](https://developer.android.com/reference/android/app/admin/DeviceAdminReceiver)

## Ayrılmış laboratuvar cihazında kurulum planı

1. Kişisel günlük tablet yerine silinebilir/yedeklenmiş bir test cihazı ayırın. Yönetim sahibini, mevcut hesapları, OEM/Android sürümünü ve kurumun kurtarma yöntemini belgeleyin. USB/EMM erişimi ve fiziksel güç düğmesi için önceden onaylı bir yol hazırlayın.
2. Aynı `com.ersingundem.larenor` paketini ve mevcut imza anahtarını kullanan APK yüklenir; görünür adı **Larenor Client** olması paket veya imza değişikliği değildir. Native kayıt/izin listesi/aktif görev kilidi başka cihaza vault ile taşınmaz.
3. Harici DPC/EMM zaten varsa yöneticisi yalnız Larenor'u izinli yapabilir. Bu senaryoda Larenor cihaz sahibi görünmez; diğer kurumsal politikaları okuyabildiğini/değiştirebildiğini iddia etmez.
4. Kendi DPC laboratuvar kurulumunda Android'in hesap içermeyen uygun cihaz üzerinde resmi ADB device-owner akışı, yetkili operatör tarafından uygulanabilir. Receiver kimliği `com.ersingundem.larenor/.kiosk.KioskAdminReceiver`'dır. Uygulama bu komutu çalıştırmaz veya cihazı uygun hale getirmek için sıfırlamaz. [Dedicated devices cookbook](https://developer.android.com/work/dpc/dedicated-devices/cookbook)
5. Önce Ayarlar PIN'i ve kurtarma provası; sonra **izin ver → gerekiyorsa güç menüsünü geri getir → kioska gir**. Her adım ayrı açık onaydır. Home/Recents, bildirimler, geri, klavye, TalkBack, çağrı/medya ve PIN ile çıkışı fiziksel cihazda sınayın. DeX, multi-window ve harici ekran uygunluk tespiti gerçek OEM cihazında ayrıca doğrulanmalıdır.

Bu dilim QR/zero-touch/EMM enrollment ürünü değildir. Android 12+ yönetilen provisioning için gereken `ACTION_GET_PROVISIONING_MODE` ve `ACTION_ADMIN_POLICY_COMPLIANCE` aktiviteleri henüz uygulanmadı; otomatik kayıt vaat edilmez. [Android 12 enterprise değişiklikleri](https://developer.android.com/work/versions/android-12)

## Kurtarma ve yönetimden çıkarma

Normal çıkış, erişilebilir Ayarlar → Ekran → Yönetilen kiosk → Görev kilidinden çık ve yeni PIN doğrulamasıdır; gizli dokunma hareketine bağlı değildir. Larenor cihaz sahibi olduğunda ayrıca kendi izin kaydını kaldırma yolu vardır. Güç menüsünü kapatma, güvenli açılışı/factory-reset'i/USB'yi engelleme veya volume kısıtı uygulanmaz. Uygulama/Activity yeniden kurulunca otomatik yeniden kilitleme yapmaz; gerçek yeniden başlatma/OEM davranışı laboratuvarda doğrulanmalıdır.

PIN unutulması, secure-store arızası veya bozuk APK için önceden kurulan yönetici/USB/OEM kurtarma prosedürü gerekir; in-app doğrulama atlanmaz. Üretim APK'sına `testOnly` eklenmez. Android'in `dpm remove-active-admin` komutu test-only admin gerektirir; release cihazı için genel kurtarma sözü olarak sunulmaz. [ADB cihaz yönetimi komutları](https://developer.android.com/tools/adb)

Yönetilen görev kilidinden çıkmak, cihaz sahipliğini kaldırmak değildir. Devreden çıkarma, ayrı yönetici işidir: kilidi sonlandır, Larenor'a ait izin kaydını kaldır, gerekli kişisel verileri şifreli olarak dışa aktar, kurumun veri silme/kayıt kaldırma prosedürünü uygula. `clearDeviceOwnerApp` API 26'dan beri test amaçlı/deprecated'dir; veri temizliğini garanti etmez. Uygulamada sahiplik kaldırma veya wipe butonu bu nedenle yoktur. [DevicePolicyManager deprovision sınırı](https://developer.android.com/reference/android/app/admin/DevicePolicyManager#clearDeviceOwnerApp(java.lang.String))

## Testler ve kalan cihaz kabulü

`test/features/kiosk`: strict channel şeması, sıfır açılış yazması, yeni PIN/kalıcı rate-limit sözleşmesi, PIN değişimi/idle/background/dispose, çift çağrı, belirsiz sonuç, stale durumun gizlenmesi, 320px/tablet 200% metin.

`android/app/src/test/.../kiosk`: pure policy ve Robolectric gerçek köprü/manifest; izin yokken sıfır start, tek kullanımlık onay, deadline/iptal, diğer allowlist paketlerini ve feature bitlerini koruma, system-only receiver, kabul/gerçek durum ayrımı. CI'daki standart Flutter testleri ve `:app:testDebugUnitTest` bu dosyaları kapsar.

Bu testler gerçek Device Owner enrollment, fiziksel tuşlarla çıkış, update/reboot, kurumsal policy çakışmaları veya OEM kurtarma provası yerine geçmez. K04'ün bu mühendislik temeli uygulanmıştır; üretim yönetilen cihaz kabulü ve provisioning akışları ayrı kalan kapsamdır.
