package top.stillmisty.molia

import io.flutter.app.FlutterApplication
import com.google.android.material.color.DynamicColors

class MoliaApplication : FlutterApplication() {
    override fun onCreate() {
        super.onCreate()
        DynamicColors.applyToActivitiesIfAvailable(this)
    }
} 