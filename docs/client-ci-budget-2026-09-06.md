# Tam Client coverage koşusuna yeterli CI iş süresi

CI105 `38e78a3` kaynakta analiz ve966dosya biçim kontrolünü geçti. Unit/widget
coverage işi12:54'te4.282 teste ulaşmışken sona erdi. GitHub annotation kesin
nedeni bildirir: `The job has exceeded the maximum execution time of 15m0s`.
Logda `[E]`, negatif sayaç veya `All tests passed` yoktur;4.282 kısmi ilerleme
tam test başarısı değildir. İş917sn, test adımı787sn sürdü.

Yerelde aynı uygulama/test ağacı5.056 testi tamamlamıştı. CI'ın gözlenen hızı
ve kurulum süresiyle kaba toplam17:40–18:06 tahmini,15dk bütçenin yetersizliğini
açıklar; heterojen testler için bu süre bir garanti değildir. Yalnız
`.github/workflows/analyze-test.yml` iş bütçesi **15→25 dakika** oldu.
Tekil test90sn, coverage, pipefail, bütün test komutu, Android/E2E süreleri ve
imzalı yayın önkoşulları değişmedi. Test atlama veya hata maskeleme yoktur.

Mevcut **207 CI politika testi45,750sn'de geçti**; backup/CI trust statik
kontrolü ve diff check temizdir. Bağımsız kaynak incelemesi tek scalar farkını
ve diğer kapıların korunduğunu doğruladı. Bu basit yapılandırma için değeri
yineleyen yeni test eklenmedi. Yeni işin gerçekten tamamlanması kendi CI
kaynağında ayrıca gözlenecek; bütçe artışı başarı iddiası değildir.

Önceki17 E2E/133faz doğal tamamlandı; APK105 işi atlandı ve APK indirmesi0.
Başarısızlık makbuzu değiştirilmedi. Kanıtlar:
`/private/tmp/larenor-38e78a3-flutter-{job-metadata,annotations}.json`,
`/private/tmp/larenor-38e78a3-flutter.log`,
`/private/tmp/larenor-38e78a3-e2e-harvest.json`,
`/private/tmp/larenor-client-ci-budget-{policy,security}.log`.
