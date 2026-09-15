#!/usr/bin/env python3
"""
Builds docs/templates/rally-certificate-modern.odt.

Why a generator instead of just committing the .odt: an ODT is a zip of XML,
so it is opaque in a diff and unreviewable in a PR. This script is the
reviewable source; the .odt is its build output. Regenerate with:

    python3 scripts/build-certificate-template.py

The thing this exists to guarantee is in Certificates::MergeOdt's own warning:
substitution is a literal gsub against the raw XML, so a {{token}} split across
two <text:span> elements never matches and the braces print on the finished
certificate. Word processors split runs silently — autocorrect capitalising a
letter mid-token is enough. Writing content.xml directly means every token is
one uninterrupted run of plain text, by construction.

Tokens (Certificates::RenderPdf#placeholder_values — these four, no others):
    {{participant_name}}  display_name, falling back to the account email
    {{event_title}}
    {{event_date}}        pre-formatted "September 14, 2026"
    {{event_location}}    may be an empty string

Font is DejaVu Sans because backend/Dockerfile installs only fonts-dejavu-core
in the image where soffice runs. Naming Helvetica or Arial here would render
fine locally and silently substitute in production, moving every line.

LAYOUT: both blocks are page-anchored frames at fixed coordinates, not ordinary
flowing paragraphs. That is the whole reason this renders reliably. A first
draft used normal paragraphs, and a long participant name — three wrapped lines
at 34pt — pushed the signature block onto a second page, producing a two-page
certificate whose second page held nothing but a rule and the word "signature".
That is not an exotic input: RenderPdf#participant_name falls back to the
account's *email address* when a profile has no display name, and those are
long. With the content page-anchored, text length can change how a block wraps
but can never paginate the document.
"""

import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "docs" / "templates" / "rally-certificate-modern.odt"

ACCENT = "#6366f1"  # frontend's default brandColor
INK = "#1a1a2e"     # primary text
MUTED = "#6b7280"   # secondary text
RULE = "#9ca3af"    # signature rule

# A4 landscape, 2.5cm margins -> 24.7cm of text width.
PAGE_W, PAGE_H, MARGIN = 29.7, 21.0, 2.5
TEXT_W = PAGE_W - (2 * MARGIN)

# Frame geometry, in absolute page coordinates.
#
# MEASURE is deliberately narrower than the text width: it sets the line length
# the name and event title wrap at. Letting them run the full 24.7cm would give
# an unreadably long measure for the 34pt name and would push the wrap point
# right up against the margin. 18cm keeps long values to two lines in practice
# and makes the right-hand whitespace look intentional rather than leftover.
MEASURE = 18.0
ACCENT_Y, ACCENT_W, ACCENT_H = 2.9, 4.0, 0.12
MAIN_X, MAIN_Y = MARGIN, 3.55
# The signature sits just above the bottom margin (21cm page - 2.5cm margin =
# 18.5cm), not floating in the middle. At 15.4cm it left the bottom fifth of
# the page visibly empty. The worst-case content — a three-line name plus a
# two-line event title — reaches roughly 14.5cm, so there is still clearance.
SIG_RULE_Y, SIG_RULE_W, SIG_RULE_H = 17.0, 7.0, 0.03
SIG_X, SIG_Y, SIG_W = MARGIN, 17.1, 8.0

NS = """xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
  xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
  xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
  xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
  xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
  xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
  xmlns:xlink="http://www.w3.org/1999/xlink"
  xmlns:dc="http://purl.org/dc/elements/1.1/"
  xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0"
  xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"
  xmlns:loext="urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0\""""

FONTS = """<office:font-face-decls>
    <style:font-face style:name="DejaVu Sans" svg:font-family="&apos;DejaVu Sans&apos;"
      style:font-family-generic="swiss" style:font-pitch="variable"/>
  </office:font-face-decls>"""


def rule_style(name, colour):
    """A filled rectangle, used for the two horizontal rules.

    The first draft drew these as empty paragraphs with a bottom border, which
    worked in ordinary body text and then silently rendered nothing once the
    content moved inside draw:text-box frames — an empty 1pt paragraph gets
    collapsed and its border clipped. A draw:rect is a real shape with its own
    geometry, so it renders the same wherever it is placed, and it is the
    honest primitive for "draw a line at these coordinates".
    """
    return f"""<style:style style:name="{name}" style:family="graphic">
      <style:graphic-properties
        draw:fill="solid" draw:fill-color="{colour}" draw:stroke="none"
        style:wrap="none" style:run-through="foreground"
        style:vertical-pos="from-top" style:vertical-rel="page"
        style:horizontal-pos="from-left" style:horizontal-rel="page"/>
    </style:style>"""


def rect(style, x, y, w, h, z):
    return (f'<draw:rect draw:style-name="{style}" text:anchor-type="page" '
            f'text:anchor-page-number="1" draw:z-index="{z}" '
            f'svg:x="{x}cm" svg:y="{y}cm" svg:width="{w}cm" svg:height="{h}cm"/>')


def frame_style(name):
    """An invisible, page-positioned text box: no border, no fill, no wrap."""
    return f"""<style:style style:name="{name}" style:family="graphic">
      <style:graphic-properties
        draw:fill="none" draw:stroke="none" fo:border="none" fo:padding="0cm"
        style:wrap="none" style:run-through="foreground"
        style:vertical-pos="from-top" style:vertical-rel="page"
        style:horizontal-pos="from-left" style:horizontal-rel="page"/>
    </style:style>"""


def para(name, size_pt, colour, *, weight="normal", tracking=None,
         space_before=0.0, space_after=0.0, transform=None):
    tp = [f'style:font-name="DejaVu Sans"', f'fo:font-size="{size_pt}pt"',
          f'fo:color="{colour}"', f'fo:font-weight="{weight}"']
    if tracking:
        tp.append(f'fo:letter-spacing="{tracking}"')
    if transform:
        tp.append(f'fo:text-transform="{transform}"')
    return f"""<style:style style:name="{name}" style:family="paragraph">
      <style:paragraph-properties fo:text-align="start"
        fo:margin-top="{space_before:.2f}cm" fo:margin-bottom="{space_after:.2f}cm"/>
      <style:text-properties {" ".join(tp)}/>
    </style:style>"""


STYLES_XML = f"""<?xml version="1.0" encoding="UTF-8"?>
<office:document-styles {NS} office:version="1.3">
  {FONTS}
  <office:styles>
    <style:default-style style:family="paragraph">
      <style:paragraph-properties fo:hyphenation-ladder-count="no-limit"/>
      <style:text-properties style:font-name="DejaVu Sans" fo:font-size="12pt" fo:color="{INK}"/>
    </style:default-style>
    <style:style style:name="Standard" style:family="paragraph" style:class="text"/>
  </office:styles>
  <office:automatic-styles>
    <style:page-layout style:name="pm1">
      <style:page-layout-properties
        fo:page-width="{PAGE_W}cm" fo:page-height="{PAGE_H}cm"
        style:print-orientation="landscape"
        fo:margin-top="{MARGIN}cm" fo:margin-bottom="{MARGIN}cm"
        fo:margin-left="{MARGIN}cm" fo:margin-right="{MARGIN}cm"
        style:writing-mode="lr-tb"/>
    </style:page-layout>
  </office:automatic-styles>
  <office:master-styles>
    <style:master-page style:name="Standard" style:page-layout-name="pm1"/>
  </office:master-styles>
</office:document-styles>"""

CONTENT_XML = f"""<?xml version="1.0" encoding="UTF-8"?>
<office:document-content {NS} office:version="1.3">
  {FONTS}
  <office:automatic-styles>
    {frame_style("FrameMain")}
    {frame_style("FrameSignature")}
    {rule_style("RectAccent", ACCENT)}
    {rule_style("RectSignature", RULE)}
    {para("Eyebrow", 10, MUTED, tracking="0.12cm", transform="uppercase", space_after=2.1)}
    {para("Name", 34, INK, space_after=0.8)}
    {para("Connector", 12, MUTED, space_after=0.3)}
    {para("EventTitle", 19, INK, weight="bold", space_after=1.1)}
    {para("Detail", 12, MUTED, space_after=0.16)}
    {para("SignatureLabel", 9, MUTED, tracking="0.04cm", transform="uppercase")}
    <style:style style:name="Anchor" style:family="paragraph">
      <style:paragraph-properties fo:margin="0cm"/>
      <style:text-properties fo:font-size="1pt" style:font-name="DejaVu Sans"/>
    </style:style>
  </office:automatic-styles>
  <office:body>
    <office:text>
      <!-- One 1pt anchor paragraph holding two page-anchored frames. The body
           text itself is therefore always a single short line and can never
           overflow onto a second page, whatever the merged values contain. -->
      <text:p text:style-name="Anchor">
        {rect("RectAccent", MARGIN, ACCENT_Y, ACCENT_W, ACCENT_H, 2)}
        <draw:frame draw:style-name="FrameMain" text:anchor-type="page"
          text:anchor-page-number="1" draw:z-index="0"
          svg:x="{MAIN_X}cm" svg:y="{MAIN_Y}cm" svg:width="{MEASURE}cm">
          <draw:text-box>
            <text:p text:style-name="Eyebrow">Certificate of completion</text:p>
            <text:p text:style-name="Name">{{{{participant_name}}}}</text:p>
            <text:p text:style-name="Connector">completed</text:p>
            <text:p text:style-name="EventTitle">{{{{event_title}}}}</text:p>
            <text:p text:style-name="Detail">{{{{event_date}}}}</text:p>
            <text:p text:style-name="Detail">{{{{event_location}}}}</text:p>
          </draw:text-box>
        </draw:frame>
        {rect("RectSignature", MARGIN, SIG_RULE_Y, SIG_RULE_W, SIG_RULE_H, 3)}
        <draw:frame draw:style-name="FrameSignature" text:anchor-type="page"
          text:anchor-page-number="1" draw:z-index="1"
          svg:x="{SIG_X}cm" svg:y="{SIG_Y}cm" svg:width="{SIG_W}cm">
          <draw:text-box>
            <text:p text:style-name="SignatureLabel">Authorised signature</text:p>
          </draw:text-box>
        </draw:frame>
      </text:p>
    </office:text>
  </office:body>
</office:document-content>"""

META_XML = f"""<?xml version="1.0" encoding="UTF-8"?>
<office:document-meta {NS} office:version="1.3">
  <office:meta>
    <meta:generator>rally scripts/build-certificate-template.py</meta:generator>
    <dc:title>Rally certificate of completion</dc:title>
    <dc:description>Template for Certificates::RenderPdf. Placeholders: {{{{participant_name}}}}, {{{{event_title}}}}, {{{{event_date}}}}, {{{{event_location}}}}.</dc:description>
  </office:meta>
</office:document-meta>"""

MANIFEST_XML = """<?xml version="1.0" encoding="UTF-8"?>
<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">
  <manifest:file-entry manifest:full-path="/" manifest:version="1.3" manifest:media-type="application/vnd.oasis.opendocument.text"/>
  <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
  <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>
  <manifest:file-entry manifest:full-path="meta.xml" manifest:media-type="text/xml"/>
</manifest:manifest>"""


def build():
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        # The mimetype entry must be first and stored uncompressed — that is
        # what lets a reader identify the format from the raw bytes without
        # inflating anything. A normal deflated entry produces a file some
        # tools refuse to open.
        z.writestr(
            zipfile.ZipInfo("mimetype"),
            "application/vnd.oasis.opendocument.text",
            compress_type=zipfile.ZIP_STORED,
        )
        z.writestr("META-INF/manifest.xml", MANIFEST_XML)
        z.writestr("content.xml", CONTENT_XML)
        z.writestr("styles.xml", STYLES_XML)
        z.writestr("meta.xml", META_XML)
    print(f"wrote {OUT.relative_to(REPO)} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    build()
