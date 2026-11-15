package dev.zeroplayer.zero_player

/** Shared by every activity-result bridge owned by MainActivity. */
internal object ActivityRequestCodes {
    const val SAVE_FILE = 7201
    const val VIDEO_DIRECTORY = 7202
    const val VIDEO_FILE = 7203
    const val PROTECTED_BOOK_EXPORT = 7204

    fun validate() {
        val codes = listOf(SAVE_FILE, VIDEO_DIRECTORY, VIDEO_FILE, PROTECTED_BOOK_EXPORT)
        check(codes.toSet().size == codes.size) { "Activity request codes must be distinct" }
    }
}
