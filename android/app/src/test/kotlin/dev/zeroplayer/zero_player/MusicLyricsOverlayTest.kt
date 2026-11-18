package dev.zeroplayer.zero_player

import android.app.Activity
import android.widget.TextView
import io.flutter.plugin.common.MethodCall
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.android.controller.ActivityController
import org.robolectric.shadows.ShadowSettings

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class MusicLyricsOverlayTest {
    private lateinit var activity: ActivityController<Activity>
    private lateinit var overlay: MusicLyricsOverlay
    private var assignments = 0

    @Before fun prepare() {
        ShadowSettings.setCanDrawOverlays(true)
        activity = Robolectric.buildActivity(Activity::class.java).setup()
        overlay = MusicLyricsOverlay(activity.get()) { assignments++ }
    }

    @After fun close() {
        overlay.hide()
        activity.pause().stop().destroy()
        ShadowSettings.setCanDrawOverlays(false)
    }

    @Test fun repeatedPayloadRetainsTheWindowAndText() {
        assertTrue(overlay.update(payload()))
        val view = field("title")
        repeat(99) { assertTrue(overlay.update(payload())) }
        assertSame(view, field("title"))
        assertEquals("歌曲", field("title")?.text.toString())
        assertEquals("歌词", field("lyric")?.text.toString())
        assertEquals("播放中", field("status")?.text.toString())
        println("music-lyrics-100-updates: textAssignments=$assignments")
        assertEquals(3, assignments)
    }

    @Test fun changedLineIsVisibleImmediately() {
        assertTrue(overlay.update(payload()))
        assertTrue(overlay.update(payload(lyric = "下一行")))
        assertEquals("下一行", field("lyric")?.text.toString())
        assertEquals("歌曲", field("title")?.text.toString())
        assertEquals(4, assignments)
    }

    @Test fun truncationUsesDisplayedText() {
        assertTrue(overlay.update(payload("歌".repeat(100) + "a", "词".repeat(300) + "a", "态".repeat(80) + "a")))
        assertTrue(overlay.update(payload("歌".repeat(100) + "b", "词".repeat(300) + "b", "态".repeat(80) + "b")))
        assertEquals(100, field("title")?.text?.length)
        assertEquals(300, field("lyric")?.text?.length)
        assertEquals(80, field("status")?.text?.length)
        assertEquals(3, assignments)
    }

    @Test fun revokedPermissionStillHidesAnUnchangedPayload() {
        assertTrue(overlay.update(payload()))
        val before = assignments
        ShadowSettings.setCanDrawOverlays(false)
        assertFalse(overlay.update(payload()))
        assertNull(field("title"))
        assertEquals(before, assignments)
        ShadowSettings.setCanDrawOverlays(true)
        assertTrue(overlay.update(payload()))
        assertEquals("歌词", field("lyric")?.text.toString())
        assertEquals(before + 3, assignments)
    }

    @Test fun hideAndRecreateAssignsTextToFreshViews() {
        assertTrue(overlay.update(payload()))
        val original = field("title")
        overlay.hide()
        overlay.hide()
        assertNull(field("title"))
        assertTrue(overlay.update(payload()))
        assertNotSame(original, field("title"))
        assertEquals("歌曲", field("title")?.text.toString())
        assertEquals(6, assignments)
    }

    @Test fun permissionCanBeGrantedAfterTheFirstUpdate() {
        ShadowSettings.setCanDrawOverlays(false)
        assertFalse(overlay.update(payload()))
        assertEquals(0, assignments)
        ShadowSettings.setCanDrawOverlays(true)
        assertTrue(overlay.update(payload()))
        assertEquals(3, assignments)
    }

    @Test fun missingFieldsClearExistingText() {
        assertTrue(overlay.update(payload()))
        assertTrue(overlay.update(MethodCall("update", emptyMap<String, Any>())))
        assertEquals("", field("title")?.text.toString())
        assertEquals("", field("lyric")?.text.toString())
        assertEquals("", field("status")?.text.toString())
        assertEquals(6, assignments)
        assertTrue(overlay.update(MethodCall("update", emptyMap<String, Any>())))
        assertEquals(6, assignments)
    }

    @Test fun activityRecreationStartsWithFreshTextViews() {
        assertTrue(overlay.update(payload()))
        val original = field("title")
        overlay.hide()
        activity.pause().stop().destroy()
        activity = Robolectric.buildActivity(Activity::class.java).setup()
        overlay = MusicLyricsOverlay(activity.get()) { assignments++ }
        assertTrue(overlay.update(payload()))
        assertNotSame(original, field("title"))
        assertEquals("歌词", field("lyric")?.text.toString())
        assertEquals(6, assignments)
    }

    private fun field(name: String): TextView? = MusicLyricsOverlay::class.java
        .getDeclaredField(name).apply { isAccessible = true }.get(overlay) as TextView?

    private fun payload(title: String = "歌曲", lyric: String = "歌词", status: String = "播放中") =
        MethodCall("update", mapOf("title" to title, "lyric" to lyric, "status" to status))
}
