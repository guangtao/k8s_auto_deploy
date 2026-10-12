#!/usr/bin/env python3
"""扫描 docker save 生成的镜像 tar，输出: 文件名<TAB>架构<TAB>归一化 name:tag
归一化规则与 lib/images.sh 的 normalize_nametag 一致：去仓库前缀、补 :latest、去掉 tag 上的架构后缀。
损坏的文件输出架构 BROKEN。用法: image_index.py <tar>...
"""
import json
import os
import re
import sys
import tarfile


def normalize(tag):
    nt = tag.split("/")[-1]
    if ":" not in nt:
        nt += ":latest"
    return re.sub(r"[-_](linux[-_])?(amd64|arm64|aarch64|x86_64)$", "", nt)


def main(files):
    for f in sorted(files):
        b = os.path.basename(f)
        try:
            with tarfile.open(f) as t:
                manifest = json.load(t.extractfile("manifest.json"))
                for e in manifest:
                    cfg = json.load(t.extractfile(e["Config"]))
                    arch = cfg.get("architecture")
                    if arch == "aarch64":
                        arch = "arm64"
                    for tag in e.get("RepoTags") or ["<none>"]:
                        print(b + "\t" + str(arch) + "\t" + normalize(tag))
        except Exception as ex:  # noqa: BLE001
            print(b + "\tBROKEN\t" + (str(ex).splitlines() or ["?"])[0])


if __name__ == "__main__":
    main(sys.argv[1:])
