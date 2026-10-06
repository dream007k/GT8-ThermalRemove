import zipfile, os
# 项目根 = 本脚本所在目录的上一级（_analysis/regress → 项目根，跨平台通用）
BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(BASE)
src = 'GT8-ThermalRemove'
out = 'GT8-ThermalRemove-v2.15.3.zip'
if os.path.exists(out):
    os.remove(out)
zf = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9)
for root, dirs, files in os.walk(src):
    dirs[:] = [d for d in dirs if d not in ('.git', '__pycache__')]
    for f in sorted(files):
        p = os.path.join(root, f)
        zf.write(p, os.path.relpath(p, src).replace(os.sep, '/'))
zf.close()
print('size:', os.path.getsize(out))

z = zipfile.ZipFile(out)
names = z.namelist()
print('files:', len(names))
prop = z.read('module.prop').decode('utf-8')
assert 'version=v2.15.3' in prop and 'versionCode=76' in prop, prop
api = z.read('webroot/cgi-bin/api.sh').decode('utf-8')
for needle in ['_cgi_origin_ok', '拒绝跨源写请求', '没有可保存的项', '_msg=$(_jesc',
               'fuse_trips', 'safe_mode', 'get_doctor']:
    assert needle in api, needle
for _lib in ['log','config','spoof','perf','system','state','fuse','doctor']:
    assert 'common/%s.sh' % _lib in names, 'common/%s.sh' % _lib
# A3：关键函数已按域搬迁到对应 lib（抽样校验，函数总数守恒见回归 Q 组）
_map = {
    'common/fuse.sh':   ['fuse_tick', 'fuse_sample_check', 'panic_to_safe', 'safe_mode_active', 'fuse_report', '_fuse_read_one'],
    'common/perf.sh':   ['unlock_perf', 'reapply_perf', 'pid_of_name', 'stop_thermal_services'],
    'common/doctor.sh': ['doctor_report', 'cleanup_stale_tmp', 'dump_temp', 'dump_cdev'],
    'common/state.sh':  ['maintain_state', 'apply_state', 'decide_state_into'],
    'common/spoof.sh':  ['apply_spoof', 'restore_spoof', 'zone_target_into'],
    'common/config.sh': ['load_conf', 'restore_sysfs', 'conf_get'],
    'common/system.sh': ['mount_config_overlays', 'unmount_config_overlays'],
    'common/log.sh':    ['_log_emit', 'log_info', '_log_level_norm'],
}
for _lib, _funcs in _map.items():
    _c = z.read(_lib).decode('utf-8')
    for _f in _funcs:
        assert _f in _c, (_lib, _f)
act = z.read('action.sh').decode('utf-8')
assert '07-fuse.txt' in act
_gl = z.read('game_list.conf').decode('utf-8')
assert 'com.mpsgame.lostabyss' in _gl, 'game_list 缺 lostabyss'
rd = z.read('README.md').decode('utf-8')
assert 'v2.15.3' in rd
assert 'common/schema.sh' in names
must = ['META-INF/com/google/android/update-binary', 'common/functions.sh',
        'common/presets.sh', 'common/conflicts.sh', 'presets/stock.conf',
        'webroot/index.html', 'webroot/cgi-bin/api.sh']
for m in must:
    assert m in names, m
print('OK: version / api / README / all files verified')
