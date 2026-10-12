#!/usr/bin/env python3
"""把同一架构的多个 docker save 镜像 tar 合并成一个，按内容地址去重共享的层（Longhorn、Calico 等镜像
共用基础层，合并后体积明显变小），并可按镜像清单只保留需要的镜像。

合并结果是标准 docker save 格式（manifest.json + 层/配置文件），`docker load -i` 一次加载全部镜像。
docker save 的层路径（旧格式 <id>/layer.tar、新格式 blobs/sha256/<digest>）都由内容决定，同名即同内容，
因此按路径取并集是安全的。不写 index.json / oci-layout（docker load 以 manifest.json 为准）。

用法:
  merge_images.py -o out.tar [-w wanted.txt] [--arch amd64] <tar>...
    -w      每行一个归一化 name:tag（与 image_index.py 规则一致）；不给则保留全部
    --arch  只保留该架构的镜像（aarch64 视为 arm64）
输出（stdout）: 每个保留的镜像一行  KEEP<TAB>name:tag<TAB>来源文件 ；跳过的为 SKIP
"""
import argparse
import io
import json
import os
import posixpath
import re
import sys
import tarfile

SKIP_META = {"manifest.json", "repositories", "index.json", "oci-layout"}


def normalize(tag):
    nt = tag.split("/")[-1]
    if ":" not in nt:
        nt += ":latest"
    return re.sub(r"[-_](linux[-_])?(amd64|arm64|aarch64|x86_64)$", "", nt)


def norm_arch(a):
    return {"aarch64": "arm64", "x86_64": "amd64"}.get(a, a)


def clean(name):
    return posixpath.normpath(name.lstrip("./")) if name not in (".", "./") else ""


def needed_paths(t, entry, members):
    """一个镜像需要的全部 tar 成员：配置、层，以及旧格式层目录下的 json/VERSION；符号链接追到目标"""
    want = [entry["Config"]] + list(entry.get("Layers") or [])
    out, stack = set(), [clean(p) for p in want]
    for p in list(stack):
        d = posixpath.dirname(p)
        if d and not d.startswith("blobs"):
            for extra in ("json", "VERSION"):
                q = posixpath.join(d, extra)
                if q in members:
                    stack.append(q)
    while stack:
        p = stack.pop()
        if p in out:
            continue
        m = members.get(p)
        if m is None:
            raise RuntimeError("tar 中缺少 " + p)
        out.add(p)
        if m.issym():
            stack.append(clean(posixpath.join(posixpath.dirname(p), m.linkname)))
        elif m.islnk():
            stack.append(clean(m.linkname))
    # 父目录也带上（旧格式 <id>/ 目录项）
    for p in list(out):
        d = posixpath.dirname(p)
        while d:
            if d in members:
                out.add(d)
            d = posixpath.dirname(d)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", required=True)
    ap.add_argument("-w")
    ap.add_argument("--arch")
    ap.add_argument("tars", nargs="+")
    a = ap.parse_args()
    wanted = None
    if a.w:
        wanted = {ln.strip() for ln in open(a.w) if ln.strip() and not ln.startswith("#")}

    written = set()
    manifest, by_config = [], {}
    tmp = a.o + ".tmp"
    with tarfile.open(tmp, "w", format=tarfile.GNU_FORMAT) as out:
        for f in sorted(a.tars):
            b = os.path.basename(f)
            with tarfile.open(f) as t:
                members = {clean(m.name): m for m in t.getmembers() if clean(m.name)}
                entries = json.load(t.extractfile(members["manifest.json"]))
                for e in entries:
                    cfg = json.load(t.extractfile(members[clean(e["Config"])]))
                    arch = norm_arch(cfg.get("architecture"))
                    tags = e.get("RepoTags") or []
                    nts = [normalize(x) for x in tags]
                    if a.arch and arch != a.arch:
                        print("SKIP\t%s\t%s（架构 %s）" % (",".join(nts) or "<none>", b, arch))
                        continue
                    if wanted is not None and not (set(nts) & wanted):
                        print("SKIP\t%s\t%s" % (",".join(nts) or "<none>", b))
                        continue
                    if not tags:
                        print("SKIP\t<none>\t%s（无 tag）" % b)
                        continue
                    for p in sorted(needed_paths(t, e, members)):
                        if p in written:
                            continue
                        m = members[p]
                        m2 = tarfile.TarInfo(p)
                        for k in ("mode", "mtime", "type", "linkname", "size", "uid", "gid"):
                            setattr(m2, k, getattr(m, k))
                        m2.uname = m2.gname = ""
                        if m.islnk():
                            m2.linkname = clean(m.linkname)
                        out.addfile(m2, t.extractfile(m) if m.isfile() else None)
                        written.add(p)
                    key = clean(e["Config"])
                    if key in by_config:
                        old = by_config[key]
                        old["RepoTags"] = sorted(set(old["RepoTags"]) | set(tags))
                    else:
                        ne = {"Config": key, "RepoTags": list(tags),
                              "Layers": [clean(x) for x in e.get("Layers") or []]}
                        if e.get("LayerSources"):
                            ne["LayerSources"] = e["LayerSources"]
                        by_config[key] = ne
                        manifest.append(ne)
                    print("KEEP\t%s\t%s" % (",".join(nts), b))
        data = json.dumps(manifest, separators=(",", ":")).encode()   # repositories 可省略，docker load 以 manifest.json 为准
        ti = tarfile.TarInfo("manifest.json")
        ti.size, ti.mode = len(data), 0o644
        out.addfile(ti, io.BytesIO(data))

    # 自检：manifest 引用的文件都在
    with tarfile.open(tmp) as t:
        names = {clean(m.name) for m in t.getmembers()}
    for e in manifest:
        for p in [e["Config"]] + e["Layers"]:
            if p not in names:
                raise SystemExit("合并结果缺少 " + p)
    os.replace(tmp, a.o)
    print("DONE\t%d 个镜像\t%d 个文件" % (len(manifest), len(written)), file=sys.stderr)


if __name__ == "__main__":
    main()
