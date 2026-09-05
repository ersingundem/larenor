package com.ersingundem.larenor.wellbeing

import android.app.Activity
import android.os.Bundle
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import java.util.Locale

/** Required Health Connect rationale surface; exported but entirely static. */
class WellbeingPrivacyActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val tr = Locale.getDefault().language == "tr"
        val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val padding = (24 * resources.displayMetrics.density).toInt()
        val text = TextView(this).apply {
            textSize = 18f
            text = if (tr) "Larenor · Kişisel sağlık verileri\n\n" +
                "Seçtiğiniz kilo, vücut yağ oranı ve adım verileri yalnızca özel sağlık ekranında göstermek için okunur. " +
                "İzin vermek okumayı kendiliğinden başlatmaz. Health Connect kayıtları değiştirilmez veya silinmez.\n\n" +
                "Bu bağlantı ölçümleri Home Assistant'a veya başka bir sunucuya göndermez; ölçümler uygulamanın günlüklerine ya da yedeklerine eklenmez. " +
                "Görüntülenen ölçümler bellekte geçici tutulur. İzinleri istediğiniz zaman Health Connect ayarlarından kaldırabilirsiniz. " +
                "Uygulamadaki eşleştirme ve profil tercihlerini uygulama ayarlarından silebilirsiniz."
            else "Larenor · Personal health data\n\n" +
                "Selected weight, body fat and step data are read only to display them in the private wellbeing screen. " +
                "Granting permission does not automatically read data. Health Connect records are never changed or deleted.\n\n" +
                "This connection does not send measurements to Home Assistant or another server, and does not add them to application logs or backups. " +
                "Displayed measurements are held temporarily in memory. You can revoke access in Health Connect settings at any time. " +
                "Mappings and profile preferences can be removed in the application's settings."
        }
        column.addView(text)
        column.addView(Button(this).apply { this.text = if (tr) "Kapat" else "Close"; setOnClickListener { finish() } })
        val scroll = ScrollView(this).apply { addView(column) }
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.setPadding(padding + bars.left, padding + bars.top, padding + bars.right, padding + bars.bottom)
            insets
        }
        scroll.setPadding(padding, padding, padding, padding)
        setContentView(scroll)
        ViewCompat.requestApplyInsets(scroll)
    }
}
