#!/usr/bin/env python3
"""Gera altstore/source.json (fonte do AltStore/SideStore) a partir das Releases v* do GitHub.

Cada Release com o asset PestanaEstudio.ipa vira uma versão; o buildVersion (CFBundleVersion)
é lido do project.yml da própria tag. Uso no CI: GITHUB_REPOSITORY e GH_TOKEN definidos.
"""
import base64
import json
import os
import re
import subprocess
import sys

REPO = os.environ.get("GITHUB_REPOSITORY", "2d87h5jcdz-hub/PestanaEstudio")
ASSET = "PestanaEstudio.ipa"


def gh(path):
    return json.loads(subprocess.check_output(["gh", "api", path]))


def build_number(tag):
    try:
        content = gh(f"repos/{REPO}/contents/project.yml?ref={tag}")["content"]
        text = base64.b64decode(content).decode("utf-8")
        match = re.search(r'CURRENT_PROJECT_VERSION:\s*"?([0-9A-Za-z.]+)', text)
        return match.group(1) if match else "1"
    except Exception as error:  # noqa: BLE001
        print(f"aviso: sem project.yml em {tag}: {error}", file=sys.stderr)
        return "1"


def plain(markdown):
    """Notas da versão em texto simples (o AltStore não renderiza Markdown)."""
    text = re.sub(r"^#+\s*", "", markdown, flags=re.M)
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    text = re.sub(r"\[(.+?)\]\((.+?)\)", r"\1", text)
    text = text.replace("`", "")
    text = re.sub(r"^- ", "• ", text, flags=re.M)
    return re.sub(r"\n{3,}", "\n\n", text).strip()[:4000]


def main():
    meta = json.load(open(os.path.join(os.path.dirname(__file__), "app.json"), encoding="utf-8"))
    versions = []
    for release in gh(f"repos/{REPO}/releases?per_page=100"):
        tag = release["tag_name"]
        if release.get("draft") or release.get("prerelease") or not re.fullmatch(r"v\d+(\.\d+)*", tag):
            continue
        asset = next((a for a in release.get("assets", []) if a["name"] == ASSET), None)
        if asset is None:
            continue
        versions.append({
            "version": tag[1:],
            "buildVersion": build_number(tag),
            "date": (release.get("published_at") or release["created_at"])[:10],
            "localizedDescription": plain(release.get("body") or ""),
            "downloadURL": asset["browser_download_url"],
            "size": asset["size"],
            "minOSVersion": meta["app"].get("minOSVersion", "16.0"),
        })
    if not versions:
        sys.exit("nenhuma Release v* com PestanaEstudio.ipa")
    versions.sort(key=lambda v: [int(x) for x in v["version"].split(".")], reverse=True)

    app = {k: v for k, v in meta["app"].items() if k != "minOSVersion"}
    app["versions"] = versions
    news = [{
        "title": f"Pestana Estúdio {v['version']}",
        "identifier": f"release-{v['version']}",
        "caption": "Versão nova disponível. Toque para ver as novidades.",
        "date": v["date"],
        "tintColor": meta["app"].get("tintColor", "#D9A441"),
        "notify": True,
        "url": f"https://github.com/{REPO}/releases/tag/v{v['version']}",
        "appID": meta["app"]["bundleIdentifier"],
    } for v in versions[:5]]

    source = dict(meta["source"])
    source.update({
        "nsfw": False,
        "featuredApps": [meta["app"]["bundleIdentifier"]],
        "apps": [app],
        "news": news,
    })
    out = os.path.join(os.path.dirname(__file__), "source.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(source, f, ensure_ascii=False, indent=2)
    print(f"source.json: {len(versions)} versão(ões); mais recente {versions[0]['version']} ({versions[0]['buildVersion']})")


if __name__ == "__main__":
    main()
