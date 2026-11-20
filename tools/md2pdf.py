#!/usr/bin/env python3
import sys, html, pathlib
import markdown
from weasyprint import HTML

def main():
    if len(sys.argv) < 4:
        print("usage: md2pdf.py INPUT.md OUTPUT.pdf TITLE")
        sys.exit(2)
    src, out, title = sys.argv[1], sys.argv[2], sys.argv[3]
    text = pathlib.Path(src).read_text(encoding="utf-8")
    body = markdown.markdown(
        text,
        extensions=["tables", "fenced_code", "sane_lists", "toc", "attr_list"],
    )
    css = pathlib.Path("docs/report.css").read_text(encoding="utf-8")
    doc = f"""<!doctype html><html><head><meta charset="utf-8">
<title>{html.escape(title)}</title><style>{css}</style></head><body>{body}</body></html>"""
    HTML(string=doc, base_url=".").write_pdf(out)
    print("wrote", out)

if __name__ == "__main__":
    main()
