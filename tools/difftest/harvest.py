#!/usr/bin/env python3
"""Harvest legacy .circ files from GitHub to cover the version-migration gates.

The CSC258 seed corpus is only source=3.6.1/3.7.2, which exercises the 4.0.0
migration gate but none of the older ones. XmlReader.considerRepairs branches on
2.3.0, 2.6.3, 2.7.2 and 4.0.0, and a missed migration makes an old file
MIS-RENDER rather than fail, so this coverage is load-bearing (plan risk #4).

Writes into $LOGISIM_CORPUS/harvested (never into the repo -- see .gitignore).
Resumable: existing files are skipped, and _harvest.json records provenance.

Usage:  LOGISIM_CORPUS=/path/to/corpus python3 harvest.py [--limit N]
"""
import argparse, base64, hashlib, json, os, re, subprocess, sys, time

VERSIONS = ["2.3.0", "2.6.3", "2.7.0", "2.7.1", "2.7.2",
            "3.0.0", "3.1.0", "3.2.0", "3.3.0", "3.4.0", "3.5.0",
            "3.6.0", "3.6.1", "3.7.0", "3.7.1", "3.7.2", "4.0.0", "4.1.0"]

def gh_json(args, retries=3):
    """Run a gh command returning JSON, tolerating transient failures."""
    for attempt in range(retries):
        p = subprocess.run(["gh"] + args, capture_output=True, text=True, timeout=120)
        if p.returncode == 0 and p.stdout.strip():
            try:
                return json.loads(p.stdout)
            except json.JSONDecodeError:
                pass
        err = (p.stderr or "").strip().splitlines()[:1]
        if any("rate limit" in e.lower() for e in err):
            time.sleep(30)
        else:
            time.sleep(3 * (attempt + 1))
    return None

def search(version, limit):
    """Find .circ blobs whose header declares this source version."""
    res = gh_json(["search", "code", f'source="{version}"',
                   "--extension", "circ", "--limit", str(limit),
                   "--json", "repository,path,sha,url"])
    return res or []

def fetch_blob(owner_repo, sha):
    res = gh_json(["api", f"/repos/{owner_repo}/git/blobs/{sha}"])
    if not res or "content" not in res:
        return None
    try:
        return base64.b64decode(res["content"]).decode("utf-8", errors="replace")
    except Exception:
        return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=60, help="hits per version")
    args = ap.parse_args()

    corpus = os.environ.get("LOGISIM_CORPUS")
    if not corpus:
        sys.exit("set LOGISIM_CORPUS to the corpus directory")
    out = os.path.join(corpus, "harvested")
    os.makedirs(out, exist_ok=True)

    index_path = os.path.join(out, "_harvest.json")
    index = json.load(open(index_path)) if os.path.exists(index_path) else {}
    seen = {v["sha256"] for v in index.values()}

    for version in VERSIONS:
        hits = search(version, args.limit)
        print(f"source={version:<6} {len(hits):>3} hits", flush=True)
        kept = 0
        for h in hits:
            repo = h.get("repository", {}).get("nameWithOwner")
            path, sha = h.get("path"), h.get("sha")
            if not (repo and path and sha):
                continue
            body = fetch_blob(repo, sha)
            if not body or "<project" not in body:
                continue
            # Trust the file's own declaration, not the search index.
            m = re.search(r'source="([^"]+)"', body)
            actual = m.group(1) if m else "unknown"
            digest = hashlib.sha256(body.encode()).hexdigest()
            if digest in seen:
                continue
            seen.add(digest)
            name = f"{actual}__{re.sub(r'[^A-Za-z0-9]', '_', repo)}__{os.path.basename(path)}"
            with open(os.path.join(out, name), "w") as f:
                f.write(body)
            index[name] = {"repo": repo, "path": path, "declared": actual,
                           "sha256": digest, "bytes": len(body)}
            kept += 1
        print(f"  kept {kept} new", flush=True)
        with open(index_path, "w") as f:
            json.dump(index, f, indent=1)

    dist = {}
    for v in index.values():
        dist[v["declared"]] = dist.get(v["declared"], 0) + 1
    print("\n=== corpus version distribution ===")
    for k in sorted(dist):
        print(f"  {k:<10} {dist[k]:>4}")
    print(f"\n{len(index)} files -> {out}")

if __name__ == "__main__":
    main()
