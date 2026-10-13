#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
k8s-deploy 统一配置 + 渲染（x86_64 / aarch64 / 混合架构）

  python3 render_config.py          渲染静态配置（inventory、运行时、存储、插件、审计、patches）
  python3 render_config.py --kk     额外渲染 KubeKey 集群配置（需要先执行节点探测，生成 config/facts.json）

只需修改下面的 config 字典。字段命名与 2.1.2 安装项目保持一致，便于迁移。
"""
import json
import os
import re
import shlex
import shutil
import sys

from jinja2 import Environment, FileSystemLoader, StrictUndefined

BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(BASE, '..'))
TEMPLATE_DIR = os.path.join(ROOT, 'template')
OUT = os.path.join(ROOT, 'config')

# =============================================================================
# 全局配置（按现场修改）
# =============================================================================
config = {
    # 部署机（执行本工具的机器）IP；可以是集群节点，也可以是独立机器
    'deploy_host': '172.88.0.147',
    # auto: 每个节点读取 /etc/os-release 自动识别；也可强制指定:
    #   centos / kylin / uos / ubuntu / openeuler / rockey
    'os_type': 'auto',

    'host': {
        # arch 可省略（自动识别 amd64/arm64）；name 将作为 K8s 节点名
        'nodes': [
            {'name': 'node1', 'host': '172.88.0.147', 'user': 'root', 'passwd': 'CHANGE_ME', 'key_dir': '/root/.ssh/id_rsa'},
            {'name': 'node2', 'host': '172.88.0.155', 'user': 'root', 'passwd': 'CHANGE_ME', 'key_dir': '/root/.ssh/id_rsa'},
            {'name': 'node3', 'host': '172.88.0.179', 'user': 'root', 'passwd': 'CHANGE_ME', 'key_dir': '/root/.ssh/id_rsa'},
        ],
        # 1: root+密码  2: 普通用户+密码+sudo  3: 密钥（与 2.1.2 一致）
        'auth_choice': '1',
        'docker_data_root': '/data/docker',
        'containerd_data_root': '/data/containerd',
        # 额外的 http 私有仓库（Harbor 本身不用写在这里）
        'insecure_registries': [],
    },
    'roles': {
        'etcd': ['node1'],
        'master': ['node1'],
        'worker': ['node1', 'node2', 'node3'],
    },

    # 镜像仓库：使用现场已有 Harbor，或由本工具在 04b 步部署（install=True）
    'harbor': {
        'registry': '10.1.72.167',   # 主机[:端口]，不带 http://；install=True 时填仓库节点的 IP
        'scheme': 'https',           # https（自签证书，跳过校验）或 http
        'project': 'kubesphereio',   # 镜像统一推到该项目（KubeKey namespaceOverride）
        'user': 'admin',             # install=True 时 Harbor 管理员固定为 admin
        'passwd': 'Harbor12345',     # install=True 时作为 Harbor admin 初始密码
        'create_project': True,      # 项目不存在时自动创建（公开项目）
        # ---- 04b 步：由本工具部署仓库（可选）----
        'install': False,
        'node': '',                  # 部署到哪个节点（host.nodes 中的 name，也可写其 IP）；留空 = 部署机
        # auto: amd64 节点装 Harbor 2.10.2；arm64 节点在 pkg/arm64/harbor/ 有 Harbor 离线安装包时装 Harbor，
        #       否则装 registry:2（Harbor 官方无 arm64 离线包）
        # harbor / registry: 强制指定
        'type': 'auto',
        'data_dir': '/data/harbor',  # 仓库数据目录（镜像存储）
    },

    'kubernetes': {
        'version': '1.33.4',         # 需与 pkg/<arch>/artifact 中的版本一致
        'cluster_name': 'cluster.local',
        'container_manager': 'containerd',
        'network_plugin': 'calico',
        'pods_cidr': '10.233.64.0/18',
        'service_cidr': '10.233.0.0/18',
        'max_pods': 210,
        'auto_renew_certs': True,
        'ntp_server': '',            # 留空 = 第一台 master
        'timezone': 'Asia/Shanghai',
    },
    'etcd': {
        'data_dir': '/var/lib/etcd',
    },

    # 控制面高可用
    #   none      单 master（或使用外部 LB 时把 vip 填成外部 LB 地址）
    #   kube-vip  KubeKey 内置 kube-vip（推荐，多 master）
    #   haproxy   KubeKey 内置：每个 worker 本地 haproxy 代理到所有 master
    #   keepalived  本工具在 master 上用容器运行 keepalived 提供 VIP（单播 VRRP）
    'lb': {
        'mode': 'none',
        'vip': '',
        'port': 6443,
        'interface': '',             # keepalived 网卡，留空自动识别（节点 IP 所在网卡）
        'virtual_router_id': 51,
    },

    # CentOS 7 (3.10 内核) x86 节点升级 kernel-lt 5.4；其它系统/架构自动跳过
    'kernel': {
        'upgrade': False,
    },

    'storage': {
        'longhorn': {
            'enabled': True,
            'data_path': '/var/lib/longhorn',
            'replicas': 2,
            'data_locality': 'best-effort',   # disabled / best-effort / strict-local
            'default_class': True,
        },
        'nfs': {
            'enabled': False,
            'server': '',                     # NFS 服务器 IP
            'path': '/data/nfs',
            # 若 NFS 服务器就是某个节点，填节点 name，工具会自动安装并配置 exports
            'server_node': '',
            'storage_class': 'nfs-storage',
            'default_class': False,
            'namespace': 'kube-system',
        },
    },

    'addons': {
        'metrics_server': {'enabled': True, 'tag': 'v0.7.2'},
        'audit': {
            'enabled': True,
            'policy_file': '/etc/kubernetes/audit/audit-policy.yaml',
            'log_path': '/var/log/kubernetes/audit.log',
            'maxage': 30,
            'maxbackup': 10,
            'maxsize': 200,
        },
    },

    # ---------------- 升级（deploy.sh upgrade）----------------
    'upgrade': {
        'upgrade_path': ['1.34.2'],          # 每步最多跨 1 个小版本
        'image_repository': '',              # 留空 = harbor.registry/harbor.project
        'pkg_dir': 'upgrade-pkg',
        'backup_dir': '/data/k8s-upgrade-backup',
        'etcd_backup': True,
        'drain': True,
        'drain_timeout': '600s',
        'drain_extra_args': '',
        'worker_batch': 1,
        'node_ready_timeout': 600,
        'ignore_preflight_errors': '',
        'min_free_gb': 5,
        'allow_cgroup_v1': False,
        'cgroupv1_fail_from_minor': 35,
        'containerd1_last_minor': 35,
        'calico_tested_max_minor': {'3.27': 29, '3.28': 30, '3.29': 31, '3.30': 33},
    },
}

SUPPORTED_OS = ('auto', 'centos', 'kylin', 'uos', 'ubuntu', 'openeuler', 'rockey')


# =============================================================================
def validate(cfg):
    e = []
    nodes = cfg['host']['nodes']
    names = [n['name'] for n in nodes]
    ips = [n['host'] for n in nodes]
    if len(names) != len(set(names)):
        e.append('host.nodes 中 name 重复')
    if len(ips) != len(set(ips)):
        e.append('host.nodes 中 host(IP) 重复')
    for role in ('etcd', 'master', 'worker'):
        for n in cfg['roles'][role]:
            if n not in names:
                e.append(f'roles.{role} 中的 {n} 不在 host.nodes 里')
    if not cfg['roles']['master']:
        e.append('roles.master 不能为空')
    if not cfg['roles']['etcd']:
        e.append('roles.etcd 不能为空')
    if len(cfg['roles']['etcd']) % 2 == 0:
        e.append('etcd 节点数应为奇数（1/3/5）')
    for n in nodes:
        for k in ('name', 'host', 'user', 'passwd', 'key_dir'):
            if '|' in str(n.get(k, '')):
                e.append(f"节点 {n['name']} 的 {k} 含有 '|'，不支持")
        if n.get('arch') and n['arch'] not in ('amd64', 'arm64'):
            e.append(f"节点 {n['name']} arch 只能是 amd64/arm64")
    if cfg['os_type'] not in SUPPORTED_OS:
        e.append(f"os_type 必须是 {SUPPORTED_OS}")
    if cfg['host']['auth_choice'] not in ('1', '2', '3'):
        e.append('auth_choice 只能是 1/2/3')
    lb = cfg['lb']
    if lb['mode'] not in ('none', 'kube-vip', 'haproxy', 'keepalived'):
        e.append('lb.mode 只能是 none/kube-vip/haproxy/keepalived')
    if lb['mode'] in ('kube-vip', 'keepalived') and not lb['vip']:
        e.append(f"lb.mode={lb['mode']} 需要填写 lb.vip")
    if len(cfg['roles']['master']) > 1 and lb['mode'] == 'none' and not lb['vip']:
        e.append('多 master 必须选择 lb.mode（推荐 kube-vip）或填写外部 LB 地址到 lb.vip')
    if lb['vip'] and lb['vip'] in ips:
        e.append('lb.vip 不能与节点 IP 相同')
    if cfg['harbor']['scheme'] not in ('http', 'https'):
        e.append('harbor.scheme 只能是 http/https')
    if '://' in cfg['harbor']['registry']:
        e.append('harbor.registry 不要带 http(s)://')
    h = cfg['harbor']
    # harbor.node 也可以直接写 IP：是某个节点的 IP 就换成节点名；是部署机 IP（不在 host.nodes 里）就当作留空
    if h.get('node') and h['node'] not in names:
        by_ip = {n['host']: n['name'] for n in nodes}
        if h['node'] in by_ip:
            h['node'] = by_ip[h['node']]
        elif h['node'] == cfg['deploy_host']:
            h['node'] = ''
    if h.get('install'):
        if h.get('type', 'auto') not in ('auto', 'harbor', 'registry'):
            e.append('harbor.type 只能是 auto/harbor/registry')
        if h.get('node') and h['node'] not in names:
            e.append(f"harbor.node={h['node']} 不在 host.nodes 里（填节点 name，如 node1；留空 = 部署机）")
        node_ip = next((n['host'] for n in nodes if n['name'] == h.get('node')), cfg['deploy_host'])
        reg_host = h['registry'].rstrip('/').split(':')[0]
        if reg_host != node_ip:
            e.append(f"harbor.install=True 时 harbor.registry 的主机部分应为仓库节点 IP {node_ip}（当前 {reg_host}）")
        if h['user'] != 'admin':
            e.append("harbor.install=True 时 harbor.user 必须为 admin")
        pw = str(h['passwd'])
        if (h.get('type') != 'registry') and not (8 <= len(pw) <= 128 and re.search(r'[a-z]', pw)
                                                   and re.search(r'[A-Z]', pw) and re.search(r'[0-9]', pw)):
            e.append('Harbor 管理员密码需 8-128 位，且同时包含大写、小写字母和数字')
    nfs = cfg['storage']['nfs']
    if nfs['enabled'] and not nfs['server']:
        e.append('storage.nfs.enabled=True 时需填写 storage.nfs.server')
    if nfs['server_node'] and nfs['server_node'] not in names:
        e.append('storage.nfs.server_node 不在 host.nodes 里')
    if nfs['enabled'] and cfg['storage']['longhorn']['enabled'] \
            and nfs['default_class'] and cfg['storage']['longhorn']['default_class']:
        e.append('longhorn 与 nfs 不能同时设为默认 StorageClass')
    prev = tuple(int(x) for x in cfg['kubernetes']['version'].lstrip('v').split('.'))
    for v in cfg['upgrade']['upgrade_path']:
        cur = tuple(int(x) for x in v.lstrip('v').split('.'))
        if cur[1] - prev[1] > 1:
            e.append(f'upgrade_path 跨越超过 1 个小版本: {v}')
        prev = cur
    return e


def build_ctx(cfg, facts=None):
    ctx = json.loads(json.dumps(cfg))
    h = cfg['harbor']
    ctx['image_repo'] = (cfg['upgrade']['image_repository'] or f"{h['registry'].rstrip('/')}/{h['project']}").rstrip('/')
    ctx['upgrade_path'] = [v.lstrip('v') for v in cfg['upgrade']['upgrade_path']]
    ctx['k8s_version'] = cfg['kubernetes']['version'].lstrip('v')
    ctx['ntp_server'] = cfg['kubernetes']['ntp_server'] or cfg['roles']['master'][0]
    names = [n['name'] for n in cfg['host']['nodes']]
    ctx['deploy_is_node'] = cfg['deploy_host'] in [n['host'] for n in cfg['host']['nodes']]
    ctx['facts'] = facts or {}
    # 每个节点的最终架构：配置优先，其次探测结果
    for n in ctx['host']['nodes']:
        n['arch'] = n.get('arch') or (facts or {}).get(n['name'], {}).get('arch', '')
    ctx['k8s_nodes'] = [n for n in names if n in set(cfg['roles']['master']) | set(cfg['roles']['worker']) | set(cfg['roles']['etcd'])]
    return ctx


def main():
    errors = validate(config)
    if errors:
        for x in errors:
            print(f'[ERROR] {x}')
        sys.exit(1)

    want_kk = '--kk' in sys.argv
    facts = None
    if want_kk:
        fp = os.path.join(OUT, 'facts.json')
        if not os.path.isfile(fp):
            print('[ERROR] 缺少 config/facts.json，请先执行: bash deploy.sh facts')
            sys.exit(1)
        with open(fp, encoding='utf-8') as f:
            facts = json.load(f)

    ctx = build_ctx(config, facts)
    env = Environment(loader=FileSystemLoader(TEMPLATE_DIR), undefined=StrictUndefined, keep_trailing_newline=True)
    env.filters['sq'] = lambda s: shlex.quote(str(s))

    def render(tpl, out):
        dst = os.path.join(OUT, out)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, 'w', encoding='utf-8', newline='\n') as f:
            f.write(env.get_template(tpl).render(ctx))
        print(f'  rendered {os.path.relpath(dst, ROOT)}')

    if want_kk:
        missing = [n['name'] for n in ctx['host']['nodes'] if n['name'] in ctx['k8s_nodes'] and not n['arch']]
        if missing:
            print(f'[ERROR] 以下节点缺少架构信息: {missing}')
            sys.exit(1)
        render('kk/cluster.yaml.j2', 'kk/cluster.yaml')
        return

    render('inventory.sh.j2', 'inventory.sh')
    render('runtime/daemon.json.j2', 'runtime/daemon.json')
    render('runtime/config.toml.j2', 'runtime/config.toml')
    for f in ('docker.service', 'containerd.service'):
        os.makedirs(os.path.join(OUT, 'runtime'), exist_ok=True)
        shutil.copy(os.path.join(TEMPLATE_DIR, 'runtime', f), os.path.join(OUT, 'runtime', f))
    if config['storage']['longhorn']['enabled']:
        render('storage/longhorn.yaml.j2', 'storage/longhorn.yaml')
    if config['storage']['nfs']['enabled']:
        render('storage/nfs-provisioner.yaml.j2', 'storage/nfs-provisioner.yaml')
    if config['addons']['metrics_server']['enabled']:
        render('addons/metrics-server.yaml.j2', 'addons/metrics-server.yaml')

    pdir = os.path.join(OUT, 'patches')
    shutil.rmtree(pdir, ignore_errors=True)
    os.makedirs(pdir)
    if config['addons']['audit']['enabled']:
        os.makedirs(os.path.join(OUT, 'audit'), exist_ok=True)
        shutil.copy(os.path.join(TEMPLATE_DIR, 'audit', 'audit-policy.yaml'), os.path.join(OUT, 'audit', 'audit-policy.yaml'))
        render('patches/kube-apiserver+json.yaml.j2', 'patches/kube-apiserver+json.yaml')
    if config['upgrade']['allow_cgroup_v1']:
        render('patches/kubeletconfiguration+strategic.yaml.j2', 'patches/kubeletconfiguration+strategic.yaml')
    print('[OK] 渲染完成')


if __name__ == '__main__':
    main()
