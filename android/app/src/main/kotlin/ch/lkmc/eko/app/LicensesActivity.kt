package dev.eko.app

import android.app.Activity
import android.app.AlertDialog
import android.os.Bundle
import android.text.Html
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.ListView
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject

/**
 * Lists every component in the generated AboutLibraries definitions
 * (res/raw/aboutlibraries.json) and every notice file under assets/licenses/, and shows
 * each one's full license and NOTICE texts. Framework classes only: works without AndroidX
 * or Compose and adds no dependency (and so no notice) of its own.
 */
class LicensesActivity : Activity() {
    private class Entry(val title: String, val subtitle: String, val load: () -> CharSequence) {
        override fun toString() = if (subtitle.isEmpty()) title else "$title\n$subtitle"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setTitle(R.string.open_source_licenses)
        val pad = (16 * resources.displayMetrics.density).toInt()
        val entries = (libraryEntries() + assetEntries()).sortedBy { it.title.lowercase() }
        val list = ListView(this).apply {
            // Edge-to-edge (targetSdk 35+): keep the rows clear of the system bars.
            fitsSystemWindows = true
            clipToPadding = false
            addHeaderView(
                TextView(context).apply {
                    setText(R.string.open_source_licenses)
                    textSize = 22f
                    setPadding(pad, pad, pad, pad / 2)
                },
                null,
                false,
            )
            adapter = ArrayAdapter(context, android.R.layout.simple_list_item_1, entries)
            onItemClickListener = AdapterView.OnItemClickListener { parent, _, position, _ ->
                show(parent.getItemAtPosition(position) as Entry, pad)
            }
        }
        setContentView(list)
    }

    private fun libraryEntries(): List<Entry> {
        val json = resources.openRawResource(R.raw.aboutlibraries).bufferedReader().use { it.readText() }
        val root = JSONObject(json)
        val licenses = root.getJSONObject("licenses")
        val libraries = root.getJSONArray("libraries")
        return (0 until libraries.length()).map { index ->
            val lib = libraries.getJSONObject(index)
            val keys = lib.optJSONArray("licenses")
            val texts = (0 until (keys?.length() ?: 0)).mapNotNull { licenses.optJSONObject(keys!!.getString(it)) }
            val name = lib.optString("name").ifBlank { lib.getString("uniqueId") }
            Entry(
                title = listOf(name, lib.optString("artifactVersion")).filter { it.isNotBlank() }.joinToString(" "),
                subtitle = texts.map { it.optString("spdxId").ifBlank { it.optString("name") } }.distinct().joinToString(", "),
            ) {
                buildString {
                    // Creators first: CC BY attribution names them (android recipe).
                    val developers = lib.optJSONArray("developers")
                    val creators = (0 until (developers?.length() ?: 0))
                        .mapNotNull { developers!!.optJSONObject(it)?.optString("name")?.takeIf { name -> name.isNotBlank() } }
                        .ifEmpty { listOfNotNull(lib.optJSONObject("organization")?.optString("name")?.takeIf { it.isNotBlank() }) }
                    if (creators.isNotEmpty()) append(creators.joinToString(", ")).append("\n\n")
                    for (field in listOf("website", "description")) {
                        lib.optString(field).takeIf { it.isNotBlank() }?.let { append(it).append("\n\n") }
                    }
                    for (text in texts) {
                        append(text.optString("name")).append("\n\n").append(text.optString("content").trim()).append("\n\n")
                    }
                }
            }
        }
    }

    /** Notices that are not library definitions, e.g. Rust-Licenses.html or a native notices file. */
    private fun assetEntries(): List<Entry> =
        assets.list("licenses").orEmpty().sorted()
            .filter { assets.list("licenses/$it").isNullOrEmpty() } // files only, not folders
            .map { file ->
                Entry(file, "") {
                    val text = assets.open("licenses/$file").bufferedReader().use { it.readText() }
                    if (file.endsWith(".html")) Html.fromHtml(text, Html.FROM_HTML_MODE_LEGACY) else text
                }
            }

    private fun show(entry: Entry, pad: Int) {
        val text = entry.load()
        val body = if (text.length <= LARGE_TEXT) {
            ScrollView(this).apply {
                addView(
                    TextView(context).apply {
                        this.text = text
                        setTextIsSelectable(true)
                        setPadding(pad, pad, pad, pad)
                    },
                )
            }
        } else {
            // The merged Google SDK notices run to about 1 MB. A single TextView would lay all
            // of it out on the main thread at once, so list it paragraph by paragraph instead.
            ListView(this).apply {
                adapter = ArrayAdapter(context, android.R.layout.simple_list_item_1, text.split(PARAGRAPH_BREAK))
            }
        }
        AlertDialog.Builder(this)
            .setTitle(entry.title)
            .setView(body)
            .setPositiveButton(android.R.string.ok, null)
            .show()
    }

    private companion object {
        const val LARGE_TEXT = 64 * 1024
        val PARAGRAPH_BREAK = Regex("""\n\s*\n""")
    }
}
