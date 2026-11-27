"""Apply iPlex's presentation to the bundled Tool Drive desktop catalog."""

from pathlib import Path
import sys


def integrated_catalog(source: Path) -> str:
    desktop = Path(__file__).resolve().parent
    style = (desktop / "archive.css").read_text(encoding="utf-8")
    gradient = (desktop.parents[1] / "Windows" / "Web" / "gradient-background.css").read_text(encoding="utf-8")
    script = (desktop / "archive.js").read_text(encoding="utf-8")
    catalog = source.read_text(encoding="utf-8")
    head, end_head, catalog = catalog.partition("</head>")
    body, end_body, tail = catalog.rpartition("</body>")
    if "<html " not in head or not end_head or not end_body:
        raise ValueError("Tool Drive catalog is missing its HTML structure")
    head = head.replace("<html ", "<html data-iplex-archive data-iplex-archive-loading ", 1)
    return f"{head}<style>\n{style}\n{gradient}</style>{end_head}{body}<script>\n{script}</script>{end_body}{tail}"


if __name__ == "__main__":
    catalog_path = Path(sys.argv[1])
    catalog_path.write_text(integrated_catalog(catalog_path), encoding="utf-8")
