import zipfile, os
# 项目根 = 本脚本所在目录的上一级（_analysis/regress → 项目根，跨平台通用）
BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(BASE)
src = 'GT8-ThermalRemove'
out = 'GT8-ThermalRemove-v2.13.0.zip'
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
assert 'version=v2.13.0' in prop and 'versionCode=65' in prop, prop
api = z.read('webroot/cgi-bin/api.sh').decode('utf-8')
for needle in ['_cgi_origin_ok', '拒绝跨源写请求', '没有可保存的项', '_msg=$(_jesc',
               'fuse_trips', 'safe_mode', 'get_doctor']:
    assert needle in api, needle
fn = z.read('common/functions.sh').decode('utf-8')
for needle in ['fuse_tick', 'fuse_sample_check', 'panic_to_safe', 'pid_of_name',
               'safe_mode_active', 'cleanup_stale_tmp', 'doctor_report']:
    assert needle in fn, needle
rd = z.read('README.md').decode('utf-8')
assert 'v2.13.0' in rd
must = ['META-INF/com/google/android/update-binary', 'common/functions.sh',
        'common/presets.sh', 'common/conflicts.sh', 'presets/stock.conf',
        'webroot/index.html', 'webroot/cgi-bin/api.sh']
for m in must:
    assert m in names, m
print('OK: version / api / README / all files verified')
