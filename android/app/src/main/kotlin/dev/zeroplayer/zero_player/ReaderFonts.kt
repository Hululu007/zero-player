package dev.zeroplayer.zero_player

import android.util.Xml
import org.xmlpull.v1.XmlPullParser
import java.io.File

/** Publicly named families and aliases from the device's actual font config. */
object ReaderFonts {
    fun systemFamilies(): List<String> {
        val names = sortedSetOf<String>()
        for (path in listOf("/system/etc/fonts.xml", "/system/etc/system_fonts.xml", "/product/etc/fonts_customization.xml")) {
            val file = File(path)
            if (!file.isFile || file.length() > 4 * 1024 * 1024) continue
            try {
                file.inputStream().use { stream ->
                    val parser = Xml.newPullParser()
                    parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
                    parser.setInput(stream, "UTF-8")
                    var event = parser.eventType
                    while (event != XmlPullParser.END_DOCUMENT) {
                        if (event == XmlPullParser.START_TAG && (parser.name == "family" || parser.name == "alias")) {
                            val name = parser.getAttributeValue(null, "name")
                            if (!name.isNullOrBlank() && name.length <= 256) names.add(name)
                        }
                        event = parser.next()
                    }
                }
            } catch (_: Exception) { /* Keep families from other config files. */ }
        }
        return names.toList()
    }
}
